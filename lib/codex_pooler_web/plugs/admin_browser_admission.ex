defmodule CodexPoolerWeb.Plugs.AdminBrowserAdmission do
  @moduledoc false

  import Plug.Conn

  alias CodexPooler.Gateway.Admission, as: GatewayAdmission

  def init(opts), do: opts

  def call(conn, _opts) do
    metadata = %{
      request_id: List.first(get_resp_header(conn, "x-request-id")),
      method: conn.method,
      path: "/" <> Enum.join(conn.path_info, "/")
    }

    case GatewayAdmission.admit_browser(metadata) do
      {:ok, lease} ->
        conn
        |> put_private(:codex_pooler_admission_lease, lease)
        |> register_before_send(fn conn ->
          GatewayAdmission.release_admission(conn.private.codex_pooler_admission_lease)
          conn
        end)

      {:error, error} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(error.status, error.message)
        |> halt()
    end
  end
end
