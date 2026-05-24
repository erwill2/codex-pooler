defmodule CodexPooler.Gateway.Runtime.Streaming.Types do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.Context, as: DispatchContext

  @type stream_dispatch_result :: map() | {:ok, map()} | {:error, term()}
  @type stream_result_callback :: (Req.Response.t(), DispatchContext.t() ->
                                     stream_dispatch_result())
end
