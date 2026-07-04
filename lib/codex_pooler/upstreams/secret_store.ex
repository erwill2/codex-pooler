defmodule CodexPooler.Upstreams.SecretStore do
  @moduledoc """
  Public write boundary for encrypted upstream account secrets.

  Secret reads stay in the lower-level secret storage module where runtime
  callers already need explicit secret-kind access. New writes should go
  through this boundary instead of the broad upstream facade.
  """

  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type secret_result ::
          {:ok, EncryptedSecret.t() | binary()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec upsert_encrypted_secret(identity_ref(), map()) :: secret_result()
  def upsert_encrypted_secret(identity_or_id, attrs) when is_map(attrs),
    do: Secrets.upsert_encrypted_secret(identity_or_id, attrs)

  @spec store_encrypted_secret(identity_ref(), map()) :: secret_result()
  def store_encrypted_secret(identity_or_id, attrs) when is_map(attrs),
    do: Secrets.store_encrypted_secret(identity_or_id, attrs)
end
