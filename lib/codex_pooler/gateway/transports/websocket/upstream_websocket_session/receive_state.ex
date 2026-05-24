defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.ReceiveState do
  @moduledoc false

  defstruct [:writer, :timeouts, :message_mapper, :terminal_upstream_error_code, body: []]

  @type t :: %__MODULE__{
          writer: (binary() -> any()),
          timeouts: map(),
          message_mapper:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.message_mapper(),
          terminal_upstream_error_code: String.t() | nil,
          body: [iodata()]
        }
end
