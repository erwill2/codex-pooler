defmodule CodexPooler.Gateway.Runtime.Dispatch.PreparedContext do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.Context

  defstruct [
    :context,
    :url,
    :token,
    :upstream_payload
  ]

  @type t :: %__MODULE__{
          context: Context.t(),
          url: String.t(),
          token: String.t(),
          upstream_payload: binary() | {:multipart, list()}
        }
end
