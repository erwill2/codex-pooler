defmodule CodexPoolerWeb.BrowserSecurityTest do
  use CodexPoolerWeb.ConnCase, async: true

  import CodexPooler.AccountsFixtures
  alias CodexPoolerWeb.BrowserSecurity

  setup do
    reset_bootstrap_state_fixture!()
    :ok
  end

  describe "secure_headers/1" do
    test "returns Content-Security-Policy along with all default secure browser headers" do
      headers = BrowserSecurity.secure_headers()

      # Custom dynamic header
      assert Map.has_key?(headers, "content-security-policy")
      assert String.contains?(headers["content-security-policy"], "default-src 'self'")

      # Default secure browser headers
      assert headers["x-frame-options"] == "SAMEORIGIN"
      assert headers["x-xss-protection"] == "1; mode=block"
      assert headers["x-content-type-options"] == "nosniff"
      assert headers["x-download-options"] == "noopen"
      assert headers["x-permitted-cross-domain-policies"] == "none"
      assert headers["cross-origin-window-policy"] == "deny"
    end
  end

  describe "HTTP pipeline browser responses" do
    test "include all merged secure headers on GET /login", %{conn: conn} do
      conn = get(conn, "/login")

      assert response_headers = conn.resp_headers

      # Convert response headers list of tuples to a map for easier assertion
      headers_map = Map.new(response_headers)

      assert headers_map["content-security-policy"] =~ "default-src 'self'"
      assert headers_map["x-frame-options"] == "SAMEORIGIN"
      assert headers_map["x-xss-protection"] == "1; mode=block"
      assert headers_map["x-content-type-options"] == "nosniff"
      assert headers_map["x-download-options"] == "noopen"
      assert headers_map["x-permitted-cross-domain-policies"] == "none"
      assert headers_map["cross-origin-window-policy"] == "deny"
    end
  end
end
