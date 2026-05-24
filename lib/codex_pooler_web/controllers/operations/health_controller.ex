defmodule CodexPoolerWeb.Operations.HealthController do
  use CodexPoolerWeb, :controller

  require Logger

  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def readiness(conn, _params) do
    case readiness_probe().query(Repo, "select 1", [], timeout: 1_000) do
      {:ok, _result} ->
        json(conn, %{status: "ready"})

      {:error, reason} ->
        Logger.warning([
          "readiness probe failed path=/readyz reason_class=",
          reason_class(reason)
        ])

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable"})
    end
  end

  defp readiness_probe do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:readiness_probe, SQL)
  end

  defp reason_class(%module{}) when is_atom(module), do: inspect(module)
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "unknown"
end
