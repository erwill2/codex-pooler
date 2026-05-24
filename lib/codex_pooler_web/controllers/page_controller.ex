defmodule CodexPoolerWeb.PageController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Accounts
  alias CodexPoolerWeb.UserAuth

  def home(conn, _params) do
    cond do
      conn.assigns.current_scope && conn.assigns.current_scope.user ->
        if conn.assigns.current_scope.user.password_change_required do
          redirect(conn, to: ~p"/password/change-required")
        else
          redirect(conn, to: UserAuth.signed_in_path(conn.assigns.current_scope.user))
        end

      Accounts.bootstrap_pending?() ->
        redirect(conn, to: ~p"/bootstrap")

      true ->
        redirect(conn, to: ~p"/login")
    end
  end
end
