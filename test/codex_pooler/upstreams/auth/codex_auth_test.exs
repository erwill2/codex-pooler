defmodule CodexPooler.Upstreams.Auth.CodexAuthTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.FakeOpenAIAuthProvider
  alias CodexPooler.Upstreams.Auth.CodexAuth

  @browser_redirect_uri "http://localhost:1455/auth/callback"
  @oauth_scope "openid profile email offline_access api.connectors.read api.connectors.invoke"

  setup do
    previous = Application.get_env(:codex_pooler, CodexAuth)

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexAuth, previous)
      else
        Application.delete_env(:codex_pooler, CodexAuth)
      end
    end)
  end

  describe "browser OAuth protocol" do
    test "pkce challenge matches S256 base64url contract" do
      verifier = "test_verifier"

      expected =
        verifier
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      assert CodexAuth.pkce_challenge(verifier) == expected
    end

    test "generated pkce pair contains a verifier and matching challenge" do
      assert %{code_verifier: verifier, code_challenge: challenge} =
               CodexAuth.generate_pkce_pair()

      assert byte_size(verifier) >= 43
      assert byte_size(verifier) <= 128
      assert challenge == CodexAuth.pkce_challenge(verifier)
    end

    test "authorization url carries the current Codex browser OAuth query shape" do
      provider = start_provider!(%{})

      url = CodexAuth.build_browser_authorization_url("state_123", "challenge_456")
      parsed = URI.parse(url)
      query = URI.decode_query(parsed.query)

      assert parsed.scheme == "http"
      assert parsed.host == "127.0.0.1"
      assert parsed.path == "/oauth/authorize"
      assert query["response_type"] == "code"
      assert query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
      assert query["redirect_uri"] == @browser_redirect_uri
      assert query["scope"] == @oauth_scope
      assert query["code_challenge"] == "challenge_456"
      assert query["code_challenge_method"] == "S256"
      assert query["state"] == "state_123"
      assert query["id_token_add_organizations"] == "true"
      assert query["codex_cli_simplified_flow"] == "true"
      assert query["originator"] == "codex_cli_rs"
      assert String.starts_with?(url, FakeOpenAIAuthProvider.url(provider))
    end

    test "authorization code exchange posts the verifier and browser redirect uri" do
      provider =
        start_provider!(%{
          "/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}
        })

      assert {:ok,
              %{
                access_token: "access-token-example",
                refresh_token: "refresh-token-example",
                id_token: id_token
              }} =
               CodexAuth.exchange_authorization_code(
                 "authorization-code-example",
                 "code-verifier-example"
               )

      assert is_binary(id_token)
      assert [request] = FakeOpenAIAuthProvider.requests(provider)
      assert request.path == "/oauth/token"

      form = FakeOpenAIAuthProvider.decode_form_request(request)
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "authorization-code-example"
      assert form["client_id"] == CodexAuth.client_id()
      assert form["code_verifier"] == "code-verifier-example"
      assert form["redirect_uri"] == @browser_redirect_uri
    end

    test "authorization code exchange returns sanitized provider failures" do
      raw_provider_value = "raw-provider-token-must-not-leak"

      provider =
        start_provider!(%{
          "/oauth/token" =>
            {400,
             %{
               "error" => "invalid_grant",
               "error_description" => raw_provider_value,
               "access_token" => raw_provider_value
             }}
        })

      assert {:error,
              %{code: :codex_oauth_exchange_failed, message: message, status: 502} = error} =
               CodexAuth.exchange_authorization_code(
                 "authorization-code-example",
                 "code-verifier-example"
               )

      assert message == "Codex token exchange failed"
      refute inspect(error) =~ raw_provider_value
      assert [_request] = FakeOpenAIAuthProvider.requests(provider)
    end

    test "invalid authorization code verifier is rejected before provider I/O" do
      provider =
        start_provider!(%{
          "/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}
        })

      assert {:error,
              %{
                code: :codex_oauth_invalid_code_verifier,
                message: "Codex OAuth code verifier is invalid",
                status: 400
              }} = CodexAuth.exchange_authorization_code("authorization-code-example", "")

      assert FakeOpenAIAuthProvider.requests(provider) == []
    end

    test "invalid authorization code is rejected before provider I/O" do
      provider =
        start_provider!(%{
          "/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}
        })

      assert {:error,
              %{
                code: :codex_oauth_invalid_authorization_code,
                message: "Codex OAuth authorization code is invalid",
                status: 400
              }} = CodexAuth.exchange_authorization_code("", "code-verifier-example")

      assert FakeOpenAIAuthProvider.requests(provider) == []
    end
  end

  describe "device-code OAuth protocol" do
    test "device-code request posts the client id and normalizes provider fields" do
      provider =
        start_provider!(%{
          "/api/accounts/deviceauth/usercode" =>
            {200,
             FakeOpenAIAuthProvider.device_code_response(
               device_auth_id: "device-auth-123",
               user_code: "USER-CODE",
               interval: "7"
             )}
        })

      assert {:ok,
              %{
                "device_auth_id" => "device-auth-123",
                "user_code" => "USER-CODE",
                "verification_url" => verification_url,
                "poll_interval_seconds" => 7
              }} = CodexAuth.request_device_code()

      assert verification_url == FakeOpenAIAuthProvider.url(provider) <> "/codex/device"
      assert [request] = FakeOpenAIAuthProvider.requests(provider)
      assert request.path == "/api/accounts/deviceauth/usercode"
      assert request.json == %{"client_id" => CodexAuth.client_id()}
    end

    test "device-code request reports unavailable provider safely" do
      start_provider!(%{
        "/api/accounts/deviceauth/usercode" =>
          {404,
           %{
             "error" => "not_found",
             "error_description" => "raw-device-provider-body-must-not-leak"
           }}
      })

      assert {:error,
              %{
                code: :codex_auth_unavailable,
                message: "Codex device authorization is unavailable",
                status: 503
              }} = CodexAuth.request_device_code()
    end

    test "device-code poll exchanges provider authorization code for tokens" do
      provider =
        start_provider!(%{
          "/api/accounts/deviceauth/token" =>
            {200,
             FakeOpenAIAuthProvider.authorization_code_response(
               authorization_code: "device-authorization-code",
               code_verifier: "device-code-verifier"
             )},
          "/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}
        })

      assert {:ok,
              %{
                access_token: "access-token-example",
                refresh_token: "refresh-token-example",
                id_token: id_token
              }} =
               CodexAuth.poll_device_authorization(%{
                 "device_auth_id" => "device-auth-123",
                 "user_code" => "USER-CODE",
                 "poll_interval_seconds" => 5
               })

      assert is_binary(id_token)
      assert [poll_request, token_request] = FakeOpenAIAuthProvider.requests(provider)
      assert poll_request.path == "/api/accounts/deviceauth/token"

      assert poll_request.json == %{
               "device_auth_id" => "device-auth-123",
               "user_code" => "USER-CODE"
             }

      form = FakeOpenAIAuthProvider.decode_form_request(token_request)
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "device-authorization-code"
      assert form["code_verifier"] == "device-code-verifier"
      assert form["redirect_uri"] == CodexAuth.device_redirect_uri()
    end

    test "device-code pending and slow_down responses keep retry hints sanitized" do
      pending_provider =
        start_provider!(%{
          "/api/accounts/deviceauth/token" => {400, %{"error" => "authorization_pending"}}
        })

      assert {:error,
              %{
                code: :codex_device_authorization_pending,
                message: "Codex device authorization is still pending",
                retry_after_seconds: 5
              }} =
               CodexAuth.poll_device_authorization(%{
                 "device_auth_id" => "device-auth-pending",
                 "user_code" => "PENDING",
                 "poll_interval_seconds" => 5
               })

      assert [_request] = FakeOpenAIAuthProvider.requests(pending_provider)

      slow_down_provider =
        start_provider!(%{
          "/api/accounts/deviceauth/token" => {400, %{"error" => "slow_down"}}
        })

      assert {:error,
              %{
                code: :codex_device_authorization_slow_down,
                message: "Codex device authorization polling should slow down",
                retry_after_seconds: 10
              }} =
               CodexAuth.poll_device_authorization(%{
                 "device_auth_id" => "device-auth-slow",
                 "user_code" => "SLOW",
                 "poll_interval_seconds" => 5
               })

      assert [_request] = FakeOpenAIAuthProvider.requests(slow_down_provider)
    end
  end

  describe "refresh-token OAuth protocol" do
    test "refresh token exchange posts the refresh grant and client id" do
      provider =
        start_provider!(%{
          "/oauth/token" =>
            {200, %{"access_token" => "new-access-token-example", "expires_in" => 3600}}
        })

      assert {:ok,
              %{
                access_token: "new-access-token-example",
                expires_in: 3600
              }} = CodexAuth.refresh_token("refresh-token-example")

      assert [request] = FakeOpenAIAuthProvider.requests(provider)
      form = FakeOpenAIAuthProvider.decode_form_request(request)
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "refresh-token-example"
      assert form["client_id"] == CodexAuth.client_id()
    end
  end

  defp start_provider!(routes) do
    {:ok, provider} = FakeOpenAIAuthProvider.start_link(routes)
    on_exit(fn -> FakeOpenAIAuthProvider.stop(provider) end)
    Application.put_env(:codex_pooler, CodexAuth, issuer: FakeOpenAIAuthProvider.url(provider))
    provider
  end
end
