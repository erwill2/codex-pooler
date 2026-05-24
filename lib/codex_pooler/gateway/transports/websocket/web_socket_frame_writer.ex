defmodule CodexPooler.Gateway.Transports.Websocket.WebSocketFrameWriter do
  @moduledoc false

  @type state :: %{
          required(:conn) => Mint.HTTP.t(),
          required(:ref) => Mint.Types.request_ref(),
          required(:websocket) => Mint.WebSocket.t(),
          optional(atom()) => term()
        }

  @spec send_frame(state(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          {:ok, state()} | {:error, term(), state()}
  def send_frame(state, frame) do
    send_frame(state, frame, &Mint.WebSocket.stream_request_body/3)
  end

  @doc false
  @spec send_frame(state(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame(), function()) ::
          {:ok, state()} | {:error, term(), state()}
  def send_frame(
        %{conn: conn, ref: ref, websocket: websocket} = state,
        frame,
        stream_request_body
      )
      when is_function(stream_request_body, 3) do
    case Mint.WebSocket.encode(websocket, frame) do
      {:ok, websocket, data} ->
        state = %{state | websocket: websocket}

        case stream_request_body.(conn, ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn}}
          {:error, conn, reason} -> {:error, reason, %{state | conn: conn}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end
end
