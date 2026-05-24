defmodule CodexPooler.Gateway.Runtime.Dispatch.ResponseContext do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.Context

  defstruct [
    :context,
    :response
  ]

  @type t :: %__MODULE__{
          context: Context.t(),
          response: Req.Response.t()
        }
end
