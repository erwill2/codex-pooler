defmodule CodexPooler.Gateway.Runtime.Dispatch.ResponseContext do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  defstruct [
    :context,
    :response
  ]

  @type t :: %__MODULE__{
          context: SelectedCandidateContext.t(),
          response: Req.Response.t()
        }
end
