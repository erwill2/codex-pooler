defmodule CodexPooler.FakeUpstream.Plug do
  @moduledoc false

  def init(pid), do: pid

  def call(conn, pid), do: CodexPooler.FakeUpstream.handle(pid, conn)
end
