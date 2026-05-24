defmodule CodexPooler.Files.RequestMetadata do
  @moduledoc """
  Request metadata required by file persistence and request logging.

  Gateway callers translate their route-specific request options into this shape
  before entering `CodexPooler.Files`.
  """

  defstruct [
    :endpoint,
    :transport,
    :route_class,
    :request_id,
    :idempotency_key,
    :client_ip,
    :user_agent,
    :request_bytes,
    :upload_bytes,
    :request_content_type,
    :now,
    defer_create_request: false
  ]

  @type t :: %__MODULE__{
          endpoint: String.t() | nil,
          transport: String.t() | nil,
          route_class: String.t() | nil,
          request_id: Ecto.UUID.t() | nil,
          idempotency_key: String.t() | nil,
          client_ip: term(),
          user_agent: String.t() | nil,
          request_bytes: non_neg_integer() | nil,
          upload_bytes: non_neg_integer() | nil,
          request_content_type: String.t() | nil,
          now: DateTime.t() | nil,
          defer_create_request: boolean()
        }

  @type attrs :: t() | map() | keyword()

  @spec build(attrs(), String.t()) :: t()
  def build(%__MODULE__{} = metadata, default_endpoint) do
    ensure_endpoint(metadata, default_endpoint)
  end

  def build(attrs, default_endpoint) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      endpoint: Map.get(attrs, :endpoint),
      transport: Map.get(attrs, :transport),
      route_class: Map.get(attrs, :route_class),
      request_id: Map.get(attrs, :request_id),
      idempotency_key: Map.get(attrs, :idempotency_key),
      client_ip: Map.get(attrs, :client_ip),
      user_agent: Map.get(attrs, :user_agent),
      request_bytes: Map.get(attrs, :request_bytes),
      upload_bytes: Map.get(attrs, :upload_bytes),
      request_content_type: Map.get(attrs, :request_content_type),
      now: Map.get(attrs, :now),
      defer_create_request: Map.get(attrs, :defer_create_request) == true
    }
    |> ensure_endpoint(default_endpoint)
  end

  defp ensure_endpoint(%__MODULE__{endpoint: endpoint} = metadata, _default_endpoint)
       when is_binary(endpoint) and endpoint != "",
       do: metadata

  defp ensure_endpoint(%__MODULE__{} = metadata, default_endpoint),
    do: %{metadata | endpoint: default_endpoint}
end
