defmodule CodexPooler.Upstreams.Secrets do
  @moduledoc """
  Encrypted upstream secret lifecycle and storage helpers.
  """

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.EncryptedSecret
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @active "active"
  @deleted UpstreamIdentity.deleted_status()
  @refresh_due UpstreamIdentity.refresh_due_status()
  @reauth_required UpstreamIdentity.reauth_required_status()
  @superseded "superseded"
  @secret_key_env "CODEX_POOLER_UPSTREAM_SECRET_KEY"
  @secret_key_bytes 32
  @secret_nonce_bytes 12
  @invalid_secret_key_message "#{@secret_key_env} must be 32 raw bytes or base64-encoded 32 bytes"

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type secret_result ::
          {:ok, EncryptedSecret.t() | binary()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec secret_status(identity_ref()) ::
          :present | :missing | :expired | :refresh_due | :reauth_required
  def secret_status(identity_or_id) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{status: @reauth_required} ->
        :reauth_required

      %UpstreamIdentity{status: @refresh_due} ->
        :refresh_due

      %UpstreamIdentity{status: @deleted} ->
        :missing

      %UpstreamIdentity{} = identity ->
        cond do
          secret_expired?(identity.metadata) -> :expired
          active_secret?(identity.id, "access_token") -> :present
          true -> :missing
        end

      nil ->
        :missing
    end
  end

  @spec upsert_encrypted_secret(identity_ref(), map()) :: secret_result()
  def upsert_encrypted_secret(identity_or_id, attrs) when is_map(attrs) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        now = now()
        attrs = atomize_attrs(attrs)
        secret_kind = attrs |> Map.fetch!(:secret_kind) |> normalize_token()

        Repo.transaction(fn ->
          Repo.update_all(
            from(secret in EncryptedSecret,
              where:
                secret.upstream_identity_id == ^identity.id and secret.secret_kind == ^secret_kind and
                  secret.status == ^@active
            ),
            set: [status: @superseded, superseded_at: now]
          )

          changeset =
            EncryptedSecret.changeset(
              %EncryptedSecret{},
              attrs
              |> Map.put(:upstream_identity_id, identity.id)
              |> Map.put(:secret_kind, secret_kind)
              |> put_default(:aad, %{})
              |> put_default(:status, @active)
              |> put_default(:created_at, now)
            )

          # Reason: insert failure must rollback the encrypted-secret transaction.
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case Repo.insert(changeset) do
            {:ok, secret} -> secret
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, secret} -> {:ok, secret}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  @spec store_encrypted_secret(identity_ref(), map()) :: secret_result()
  def store_encrypted_secret(identity_or_id, attrs) when is_map(attrs) do
    with %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id),
         {:ok, plaintext} <- plaintext_secret(attrs),
         {:ok, encrypted_attrs} <- encrypt_upstream_secret(identity, attrs, plaintext) do
      upsert_encrypted_secret(identity, encrypted_attrs)
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      {:error, _reason} = error ->
        error
    end
  end

  @spec decrypt_active_secret(identity_ref(), String.t()) ::
          {:ok, binary()} | {:error, lifecycle_error()}
  def decrypt_active_secret(identity_or_id, secret_kind) when is_binary(secret_kind) do
    identity_id = identity_id(identity_or_id)
    normalized_kind = normalize_token(secret_kind)

    secret =
      Repo.one(
        from secret in EncryptedSecret,
          where:
            secret.upstream_identity_id == ^identity_id and secret.secret_kind == ^normalized_kind and
              secret.status == ^@active,
          order_by: [desc: secret.created_at],
          limit: 1
      )

    case secret do
      %EncryptedSecret{} ->
        decrypt_upstream_secret(secret)

      nil ->
        {:error,
         lifecycle_error(:upstream_secret_not_found, "active upstream secret was not found")}
    end
  end

  @spec list_active_encrypted_secrets(identity_ref()) :: [EncryptedSecret.t()]
  def list_active_encrypted_secrets(identity_or_id) do
    case identity_id(identity_or_id) do
      identity_id when is_binary(identity_id) ->
        Repo.all(
          from secret in EncryptedSecret,
            where: secret.upstream_identity_id == ^identity_id and secret.status == ^@active,
            order_by: [asc: secret.secret_kind]
        )

      nil ->
        []
    end
  end

  @spec validate_upstream_secret_key!(binary() | nil) :: :ok
  def validate_upstream_secret_key!(configured_key) do
    case decode_upstream_secret_key(configured_key) do
      {:ok, _key} -> :ok
      {:error, _reason} -> raise @invalid_secret_key_message
    end
  end

  @spec revoke_active_secrets(Ecto.UUID.t(), DateTime.t()) :: {non_neg_integer(), nil | [term()]}
  def revoke_active_secrets(identity_id, timestamp) do
    Repo.update_all(
      from(secret in EncryptedSecret,
        where: secret.upstream_identity_id == ^identity_id and secret.status == ^@active
      ),
      set: [status: "revoked", superseded_at: timestamp]
    )
  end

  defp active_secret?(identity_id, secret_kind) do
    secret_kind = normalize_token(secret_kind)

    Repo.exists?(
      from secret in EncryptedSecret,
        where:
          secret.upstream_identity_id == ^identity_id and secret.secret_kind == ^secret_kind and
            secret.status == ^@active
    )
  end

  defp secret_expired?(metadata) when is_map(metadata) do
    metadata
    |> Map.get("access_token_expires_at", Map.get(metadata, "secret_expires_at"))
    |> parse_optional_datetime()
    |> case do
      %DateTime{} = expires_at -> DateTime.compare(expires_at, now()) != :gt
      nil -> false
    end
  end

  defp secret_expired?(_metadata), do: false

  defp encrypt_upstream_secret(%UpstreamIdentity{} = identity, attrs, plaintext) do
    attrs = atomize_attrs(attrs)
    secret_kind = attrs |> Map.fetch!(:secret_kind) |> normalize_token()

    with {:ok, key} <- upstream_secret_key() do
      key_version = Map.get(attrs, :key_version) || upstream_secret_key_version()
      nonce = :crypto.strong_rand_bytes(@secret_nonce_bytes)

      aad = %{
        "algorithm" => "AES-256-GCM",
        "key_env" => @secret_key_env,
        "upstream_identity_id" => identity.id,
        "secret_kind" => secret_kind,
        "key_version" => key_version
      }

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          aad_binary(aad),
          true
        )

      ciphertext = IO.iodata_to_binary(ciphertext)
      tag = IO.iodata_to_binary(tag)

      {:ok,
       attrs
       |> Map.drop([:plaintext, :secret, "plaintext", "secret"])
       |> Map.merge(%{
         secret_kind: secret_kind,
         key_version: key_version,
         ciphertext: tag <> ciphertext,
         nonce: nonce,
         aad: aad
       })}
    end
  end

  defp decrypt_upstream_secret(%EncryptedSecret{} = secret) do
    with {:ok, key} <- upstream_secret_key(),
         <<tag::binary-size(16), ciphertext::binary>> <- secret.ciphertext,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             secret.nonce,
             ciphertext,
             aad_binary(secret.aad),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      :error ->
        {:error,
         lifecycle_error(
           :upstream_secret_decryption_failed,
           "upstream secret could not be decrypted"
         )}

      false ->
        {:error,
         lifecycle_error(
           :upstream_secret_decryption_failed,
           "upstream secret could not be decrypted"
         )}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error,
         lifecycle_error(
           :upstream_secret_invalid_ciphertext,
           "upstream secret ciphertext is invalid"
         )}
    end
  end

  defp plaintext_secret(attrs) do
    attrs = atomize_attrs(attrs)

    case Map.get(attrs, :plaintext) || Map.get(attrs, :secret) do
      plaintext when is_binary(plaintext) and byte_size(plaintext) > 0 ->
        {:ok, plaintext}

      _value ->
        {:error,
         lifecycle_error(
           :upstream_secret_plaintext_required,
           "plaintext upstream secret is required"
         )}
    end
  end

  defp upstream_secret_key do
    configured =
      :codex_pooler
      |> Application.get_env(CodexPooler.Upstreams, [])
      |> Keyword.get(:upstream_secret_key)

    configured = configured || System.get_env(@secret_key_env)

    cond do
      is_binary(configured) ->
        decode_upstream_secret_key(configured)

      local_secret_key_fallback?() ->
        {:ok, :crypto.hash(:sha256, "codex-pooler-local-upstream-secret-key")}

      true ->
        {:error,
         lifecycle_error(
           :upstream_secret_key_missing,
           "#{@secret_key_env} must be configured before storing upstream secrets"
         )}
    end
  end

  defp upstream_secret_key_version do
    :codex_pooler
    |> Application.get_env(CodexPooler.Upstreams, [])
    |> Keyword.get(:upstream_secret_key_version, "v1")
  end

  defp decode_upstream_secret_key(key) when byte_size(key) == @secret_key_bytes, do: {:ok, key}

  defp decode_upstream_secret_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == @secret_key_bytes ->
        {:ok, decoded}

      _invalid ->
        {:error,
         lifecycle_error(
           :upstream_secret_key_invalid,
           @invalid_secret_key_message
         )}
    end
  end

  defp decode_upstream_secret_key(_key) do
    {:error,
     lifecycle_error(
       :upstream_secret_key_invalid,
       @invalid_secret_key_message
     )}
  end

  defp local_secret_key_fallback? do
    # Reason: Mix is optional at release runtime, so call it only after ensure_loaded?.
    # credo:disable-for-lines:3 Credo.Check.Refactor.Apply
    Code.ensure_loaded?(Mix) and
      apply(Mix, :env, []) in [:dev, :test]
  end

  defp aad_binary(aad) when is_map(aad) do
    aad
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> :erlang.term_to_binary()
  end

  defp parse_optional_datetime(%DateTime{} = datetime), do: datetime

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp parse_optional_datetime(_value), do: nil

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil

  defp atomize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_token(value), do: value

  defp lifecycle_error(code, message), do: %{code: code, message: message}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
