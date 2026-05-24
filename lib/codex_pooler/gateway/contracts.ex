defmodule CodexPooler.Gateway.Contracts do
  @moduledoc false

  @type response_headers :: [{String.t(), String.t()}]
  @type gateway_error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t() | atom(),
          required(:message) => String.t(),
          optional(:param) => String.t() | nil,
          optional(:candidate_exclusions) => [map()],
          optional(:quota_refresh_attempted) => boolean(),
          optional(:route_class) => String.t()
        }
  @type body_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:body) => map()
        }
  @type raw_body_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:raw_body) => binary()
        }
  @type stream_callback :: (Plug.Conn.t() -> {:ok, Plug.Conn.t()} | {:error, gateway_error()})
  @type stream_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:stream) => stream_callback()
        }
  @type websocket_stream_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:websocket_stream) => (-> :ok | {:error, gateway_error()})
        }
  @type websocket_messages_result :: %{
          required(:status) => pos_integer(),
          optional(:headers) => response_headers(),
          required(:websocket_messages) => [binary() | map()]
        }
  @type gateway_result ::
          body_result()
          | raw_body_result()
          | stream_result()
          | websocket_stream_result()
          | websocket_messages_result()
end
