defmodule CodexPooler.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CodexPoolerWeb.Telemetry,
      CodexPooler.Repo,
      CodexPooler.Gateway.Transports.Admission,
      {Registry,
       keys: :unique,
       name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Registry},
      {Task.Supervisor,
       name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.TaskSupervisor},
      {Task.Supervisor, name: CodexPooler.RateLimitEventSupervisor, max_children: 4},
      {Phoenix.PubSub, name: CodexPooler.PubSub},
      CodexPooler.InstanceSettings.Cache,
      {Oban, Application.fetch_env!(:codex_pooler, Oban)},
      {DNSCluster,
       query: Application.get_env(:codex_pooler, :dns_cluster_query) || :ignore,
       resolver: CodexPooler.Platform.DNSClusterResolver},
      CodexPoolerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: CodexPooler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CodexPoolerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
