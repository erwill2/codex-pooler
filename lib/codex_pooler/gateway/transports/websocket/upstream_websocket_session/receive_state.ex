defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.ReceiveState do
  @moduledoc false

  defstruct [
    :writer,
    :timeouts,
    :message_mapper,
    :frame_observer,
    :terminal_upstream_error_code,
    downstream_output_started?: false,
    body: "",
    websocket_frame_headers: %{}
  ]

  @type t :: %__MODULE__{
          writer: (binary() -> any()),
          timeouts: map(),
          message_mapper:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.message_mapper(),
          frame_observer:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.Request.frame_observer(),
          terminal_upstream_error_code: String.t() | nil,
          downstream_output_started?: boolean(),
          websocket_frame_headers: %{optional(String.t()) => String.t()},
          body: binary()
        }
end
