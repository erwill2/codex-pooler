defmodule CodexPoolerWeb.Plugs.TrustedProxyRemoteIp do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    settings = OperationalSettings.current()

    conn
    |> Plug.Conn.put_private(:codex_pooler_peer_ip, conn.remote_ip)
    |> then(&%{&1 | remote_ip: Firewall.client_ip(&1, settings)})
  end
end
