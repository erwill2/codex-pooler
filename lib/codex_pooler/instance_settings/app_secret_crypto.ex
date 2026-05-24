defmodule CodexPooler.InstanceSettings.AppSecretCrypto do
  @moduledoc false

  @secret_key_env "CODEX_POOLER_UPSTREAM_SECRET_KEY"
  @secret_key_bytes 32
  @secret_nonce_bytes 12

  @type encrypted_secret :: %{
          required(:ciphertext) => binary(),
          required(:nonce) => binary(),
          required(:aad) => map(),
          required(:key_version) => String.t()
        }

  @spec encrypt(binary(), String.t()) :: {:ok, encrypted_secret()} | {:error, map()}
  def encrypt(plaintext, secret_kind) when is_binary(plaintext) and is_binary(secret_kind) do
    with {:ok, key} <- secret_key() do
      key_version = secret_key_version()
      nonce = :crypto.strong_rand_bytes(@secret_nonce_bytes)

      aad = %{
        "algorithm" => "AES-256-GCM",
        "key_env" => @secret_key_env,
        "key_version" => key_version,
        "secret_kind" => normalize_secret_kind(secret_kind)
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

      {:ok,
       %{
         ciphertext: IO.iodata_to_binary(tag) <> IO.iodata_to_binary(ciphertext),
         nonce: nonce,
         aad: aad,
         key_version: key_version
       }}
    end
  end

  @spec decrypt(binary(), binary(), map()) :: {:ok, binary()} | {:error, map()}
  def decrypt(ciphertext, nonce, aad)
      when is_binary(ciphertext) and is_binary(nonce) and is_map(aad) do
    with {:ok, key} <- secret_key(),
         <<tag::binary-size(16), payload::binary>> <- ciphertext,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             payload,
             aad_binary(aad),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      :error -> {:error, lifecycle_error(:app_secret_decryption_failed)}
      {:error, _reason} = error -> error
      _invalid -> {:error, lifecycle_error(:app_secret_invalid_ciphertext)}
    end
  end

  @spec hmac_digest(binary()) :: {:ok, binary()} | {:error, map()}
  def hmac_digest(plaintext) when is_binary(plaintext) do
    with {:ok, key} <- secret_key() do
      {:ok, :crypto.mac(:hmac, :sha256, key, plaintext)}
    end
  end

  @spec verify_hmac(binary(), binary()) :: boolean()
  def verify_hmac(plaintext, expected_digest)
      when is_binary(plaintext) and is_binary(expected_digest) do
    case hmac_digest(plaintext) do
      {:ok, digest} -> Plug.Crypto.secure_compare(digest, expected_digest)
      {:error, _reason} -> false
    end
  end

  def verify_hmac(_plaintext, _expected_digest), do: false

  @spec safe_fingerprint(binary()) :: String.t()
  def safe_fingerprint(plaintext) when is_binary(plaintext) do
    plaintext
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
    |> then(&"sha256:#{&1}")
  end

  @spec key_version() :: String.t()
  def key_version, do: secret_key_version()

  defp secret_key do
    configured =
      :codex_pooler
      |> Application.get_env(CodexPooler.Upstreams, [])
      |> Keyword.get(:upstream_secret_key)

    configured = configured || System.get_env(@secret_key_env)

    cond do
      is_binary(configured) ->
        decode_secret_key(configured)

      local_secret_key_fallback?() ->
        {:ok, :crypto.hash(:sha256, "codex-pooler-local-upstream-secret-key")}

      true ->
        {:error, lifecycle_error(:app_secret_key_missing)}
    end
  end

  defp secret_key_version do
    :codex_pooler
    |> Application.get_env(CodexPooler.Upstreams, [])
    |> Keyword.get(:upstream_secret_key_version, "v1")
  end

  defp decode_secret_key(key) when byte_size(key) == @secret_key_bytes, do: {:ok, key}

  defp decode_secret_key(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == @secret_key_bytes -> {:ok, decoded}
      _invalid -> {:error, lifecycle_error(:app_secret_key_invalid)}
    end
  end

  defp local_secret_key_fallback? do
    Code.ensure_loaded?(Mix) and Mix.env() in [:dev, :test]
  end

  defp aad_binary(aad) when is_map(aad) do
    aad
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> :erlang.term_to_binary()
  end

  defp normalize_secret_kind(value), do: value |> String.trim() |> String.downcase()

  defp lifecycle_error(code) do
    %{code: code, message: "instance setting secret operation failed"}
  end
end
