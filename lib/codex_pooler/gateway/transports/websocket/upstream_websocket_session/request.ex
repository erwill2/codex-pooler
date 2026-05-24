defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.Request do
  @moduledoc false

  defstruct [:url, :headers, :payload, :timeouts, :writer, :message_mapper]

  @type writer :: (binary() -> any())

  @type t :: %__MODULE__{
          url: binary(),
          headers: [{binary(), binary()}],
          payload: binary(),
          timeouts: map(),
          writer: writer(),
          message_mapper:
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.message_mapper()
        }
end
