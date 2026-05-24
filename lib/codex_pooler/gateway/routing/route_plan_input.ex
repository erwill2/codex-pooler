defmodule CodexPooler.Gateway.Routing.RoutePlanInput do
  @moduledoc """
  Explicit request identity used when planning gateway routes.
  """

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Payloads.RequestOptions

  defstruct [:request_id, :correlation_id]

  @type t :: %__MODULE__{
          request_id: Ecto.UUID.t() | nil,
          correlation_id: String.t()
        }

  @spec from_reserved(%{required(:request) => Request.t(), optional(atom()) => term()}) :: t()
  def from_reserved(%{request: %{correlation_id: correlation_id} = request}) do
    %__MODULE__{
      request_id: string_or_nil(Map.get(request, :id)),
      correlation_id: correlation_id(correlation_id)
    }
  end

  @spec from_request_opts(RequestOptions.t()) :: t()
  def from_request_opts(%RequestOptions{} = request_options) do
    %__MODULE__{
      request_id: nil,
      correlation_id: correlation_id(request_options.request_metadata.request_id)
    }
  end

  defp correlation_id(value) when is_binary(value) and value != "", do: value
  defp correlation_id(_value), do: Ecto.UUID.generate()

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
end
