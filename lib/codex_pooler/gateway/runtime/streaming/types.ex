defmodule CodexPooler.Gateway.Runtime.Streaming.Types do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  @type stream_dispatch_result :: map() | {:ok, map()} | {:error, term()}
  @type stream_result_callback :: (Req.Response.t(), SelectedCandidateContext.t() ->
                                     stream_dispatch_result())
end
