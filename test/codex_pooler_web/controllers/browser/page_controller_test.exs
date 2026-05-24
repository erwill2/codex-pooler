defmodule CodexPoolerWeb.Browser.PageControllerTest do
  use CodexPoolerWeb.ConnCase

  import CodexPooler.AccountsFixtures

  setup do
    reset_bootstrap_state_fixture!()
    :ok
  end

  test "GET / redirects to bootstrap before first setup", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/bootstrap"
  end

  test "GET / redirects to login after bootstrap for anonymous users", %{conn: conn} do
    bootstrap_owner_fixture()

    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end
end
