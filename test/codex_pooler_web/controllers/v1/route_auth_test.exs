defmodule CodexPoolerWeb.V1.RouteAuthTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.V1.UnsupportedRoutes

  @supported_routes [
    {:get, "/v1/models", nil},
    {:get, "/v1/responses", nil},
    {:post, "/v1/responses", %{"model" => "gpt-fixture-text", "input" => "synthetic text"}},
    {:post, "/v1/responses/compact",
     %{"model" => "gpt-fixture-text", "input" => "synthetic text"}},
    {:post, "/v1/chat/completions",
     %{
       "model" => "gpt-fixture-text",
       "messages" => [%{"role" => "user", "content" => "synthetic text"}]
     }},
    {:get, "/v1/usage", nil},
    {:get, "/v1/files", nil},
    {:post, "/v1/files", %{"purpose" => "user_data"}},
    {:post, "/v1/audio/transcriptions", %{"model" => "gpt-4o-transcribe"}},
    {:post, "/v1/images/generations",
     %{"model" => "gpt-image-1", "prompt" => "synthetic image request"}},
    {:post, "/v1/images/edits", %{"model" => "gpt-image-1", "prompt" => "synthetic edit request"}}
  ]

  @unsupported_routes UnsupportedRoutes.test_routes()

  describe "mandatory /v1 bearer API-key auth" do
    test "unauthenticated /v1 requests return OpenAI-shaped 401", %{conn: conn} do
      for {method, path, body} <- @supported_routes do
        conn = conn |> recycle() |> dispatch_v1(method, path, body)

        assert_openai_error(conn, 401,
          code: "api_key_missing",
          message: "api key is required"
        )
      end

      assert_no_gateway_side_effects()
    end

    test "invalid bearer keys return OpenAI-shaped 401", %{conn: conn} do
      for path <- ["/v1/models", "/v1/responses"] do
        conn =
          conn
          |> recycle()
          |> put_req_header("authorization", "Bearer sk-cxp-invalid-fixture")
          |> get(path)

        assert_openai_error(conn, 401,
          code: "api_key_missing",
          message: "api key is required"
        )
      end

      assert_no_gateway_side_effects()
    end

    test "websocket upgrade-shaped GET /v1/responses denies missing and invalid bearer before upgrade",
         %{conn: conn} do
      missing_bearer =
        conn
        |> websocket_upgrade_headers()
        |> get("/v1/responses")

      assert_openai_error(missing_bearer, 401,
        code: "api_key_missing",
        message: "api key is required"
      )

      invalid_bearer =
        build_conn()
        |> websocket_upgrade_headers()
        |> put_req_header("authorization", "Bearer sk-cxp-invalid-fixture")
        |> get("/v1/responses")

      assert_openai_error(invalid_bearer, 401,
        code: "api_key_missing",
        message: "api key is required"
      )

      assert get_resp_header(missing_bearer, "sec-websocket-accept") == []
      assert get_resp_header(invalid_bearer, "sec-websocket-accept") == []
      assert_no_gateway_side_effects()
    end

    test "disabled API keys return OpenAI-shaped 401", %{conn: conn} do
      setup = paused_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> get("/v1/models")

      assert_openai_error(conn, 401,
        code: "api_key_disabled",
        message: "api key is disabled"
      )

      assert_no_gateway_side_effects()
    end

    test "valid enabled API keys reject unsupported fields with OpenAI-shaped 400", %{conn: conn} do
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic text",
          "logprobs" => true
        })

      assert_openai_error(conn, 400,
        code: "unsupported_parameter",
        param: "logprobs",
        message: "Unsupported parameter: logprobs"
      )

      assert_no_gateway_side_effects()
    end

    @tag :disabled_pool
    test "valid keys for disabled pools fail before returning an auth context", %{conn: conn} do
      setup = active_api_key_fixture()

      setup.pool
      |> Ecto.Changeset.change(%{status: "disabled"})
      |> Repo.update!()

      conn =
        conn
        |> auth(setup)
        |> get("/v1/models")

      assert_openai_error(conn, 401,
        code: "api_key_missing",
        message: "api key is required"
      )

      assert_no_gateway_side_effects()
    end

    test "active pools with v1 compatibility disabled return OpenAI-shaped 403", %{conn: conn} do
      setup = active_api_key_fixture()

      setup.pool
      |> Pools.ensure_routing_settings()
      |> Ecto.Changeset.change(%{v1_compatibility_enabled: false})
      |> Repo.update!()

      conn =
        conn
        |> auth(setup)
        |> get("/v1/models")

      assert_openai_error(conn, 403,
        code: "v1_compatibility_disabled",
        message: "OpenAI /v1 compatibility is disabled for this pool"
      )

      assert_no_gateway_side_effects()
    end
  end

  describe "unsupported /v1 public OpenAI surfaces" do
    test "unsupported route registry lists the SDK-probed endpoint shapes exactly" do
      assert @unsupported_routes == [
               {:post, "/v1/images/variations"},
               {:post, "/v1/embeddings"},
               {:post, "/v1/batches"},
               {:post, "/v1/moderations"},
               {:post, "/v1/fine_tuning/jobs"},
               {:get, "/v1/responses/resp_fixture"},
               {:post, "/v1/responses/resp_fixture/cancel"},
               {:delete, "/v1/responses/resp_fixture"}
             ]
    end

    test "/v1/realtime remains outside the public route surface", %{conn: conn} do
      setup = active_api_key_fixture()

      for path <- ["/v1/realtime", "/v1/realtime/sessions"] do
        conn = conn |> recycle() |> auth(setup) |> get(path)

        assert html_response(conn, 404) =~ "Not Found"
        refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
      end

      assert_no_gateway_side_effects()
    end

    test "legacy public OpenAI endpoints return deterministic OpenAI-shaped 404", %{conn: conn} do
      setup = active_api_key_fixture()

      for {method, path} <- @unsupported_routes do
        conn = conn |> recycle() |> auth(setup) |> dispatch_v1(method, path, %{})

        assert_openai_error(conn, 404,
          code: "unsupported_endpoint",
          message: "Unsupported OpenAI /v1 endpoint"
        )

        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "application/json"
      end

      assert_no_gateway_side_effects()
    end

    test "unsupported POST routes reject malformed JSON before body parsing", %{conn: conn} do
      setup = active_api_key_fixture()

      for {_method, path} <- Enum.filter(@unsupported_routes, &match?({:post, _path}, &1)) do
        conn =
          conn
          |> recycle()
          |> auth(setup)
          |> put_req_header("content-type", "application/json")
          |> post(path, "{not-json")

        assert_openai_error(conn, 404,
          code: "unsupported_endpoint",
          message: "Unsupported OpenAI /v1 endpoint"
        )
      end

      assert_no_gateway_side_effects()
    end

    test "unsupported POST routes preserve auth and compatibility gates before oversized parsing",
         %{
           conn: conn
         } do
      setup = active_api_key_fixture()
      oversized_body = "{" <> String.duplicate("x", 9_000_000)

      unauthenticated =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/embeddings", oversized_body)

      assert_openai_error(unauthenticated, 401,
        code: "api_key_missing",
        message: "api key is required"
      )

      setup.pool
      |> Ecto.Changeset.change(%{status: "disabled"})
      |> Repo.update!()

      disabled_pool =
        build_conn()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/batches", oversized_body)

      assert_openai_error(disabled_pool, 401,
        code: "api_key_missing",
        message: "api key is required"
      )

      assert_no_gateway_side_effects()
    end

    test "unsupported multipart routes return deterministic errors before multipart parsing", %{
      conn: conn
    } do
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "multipart/form-data; boundary=missing-boundary")
        |> post("/v1/images/variations", "not a valid multipart body")

      assert_openai_error(conn, 404,
        code: "unsupported_endpoint",
        message: "Unsupported OpenAI /v1 endpoint"
      )

      assert_no_gateway_side_effects()
    end
  end

  describe "legacy admin and dashboard surfaces stay blocked" do
    test "/api/admin/* remains blocked as standard non-runtime 404", %{conn: conn} do
      conn = get(conn, "/api/admin/pools")

      assert html_response(conn, 404) =~ "Not Found"
      refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
    end

    test "/dashboard/* remains blocked as standard non-runtime 404", %{conn: conn} do
      conn = get(conn, "/dashboard")

      assert html_response(conn, 404) =~ "Not Found"
      refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
    end

    test "dashboard JSON API paths remain blocked as standard non-runtime 404", %{conn: conn} do
      for path <- ["/dashboard/api/requests", "/dashboard/api/pools", "/api/dashboard/requests"] do
        conn = conn |> recycle() |> get(path)

        assert html_response(conn, 404) =~ "Not Found"
        refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
      end
    end
  end

  defp dispatch_v1(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_v1(conn, :post, path, body), do: post(conn, path, body || %{})
  defp dispatch_v1(conn, :delete, path, _body), do: delete(conn, path)

  defp auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  defp websocket_upgrade_headers(conn) do
    conn
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
  end

  defp assert_openai_error(conn, status, opts) do
    assert %{"error" => error} = json_response(conn, status)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == Keyword.fetch!(opts, :code)
    assert error["message"] == Keyword.fetch!(opts, :message)
    assert error["param"] == Keyword.get(opts, :param)
  end

  defp assert_no_gateway_side_effects do
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end
end
