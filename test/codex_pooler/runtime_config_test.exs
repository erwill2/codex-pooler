defmodule CodexPooler.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @required_env %{
    "DATABASE_URL" => "ecto://user:pass@example.invalid/db",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "PHX_SERVER" => "false",
    "PORT" => "4101",
    "CODEX_POOLER_TOTP_ENCRYPTION_KEY" => "example-totp-key",
    "CODEX_POOLER_UPSTREAM_SECRET_KEY" => String.duplicate("r", 32)
  }

  test "prod endpoint http config keeps the configured port and binds IPv4" do
    with_env(@required_env, fn ->
      config = Config.Reader.read!("config/runtime.exs", env: :prod)
      endpoint_config = config[:codex_pooler][CodexPoolerWeb.Endpoint]

      assert endpoint_config[:http][:port] == 4101
      assert endpoint_config[:http][:ip] == {0, 0, 0, 0}
    end)
  end

  test "PHX_SERVER must be explicitly truthy to start the endpoint" do
    with_env(Map.put(@required_env, "PHX_SERVER", "false"), fn ->
      config = Config.Reader.read!("config/runtime.exs", env: :prod)
      endpoint_config = config[:codex_pooler][CodexPoolerWeb.Endpoint]

      refute endpoint_config[:server]
    end)

    with_env(Map.put(@required_env, "PHX_SERVER", "true"), fn ->
      config = Config.Reader.read!("config/runtime.exs", env: :prod)
      endpoint_config = config[:codex_pooler][CodexPoolerWeb.Endpoint]

      assert endpoint_config[:server]
    end)
  end

  test "prod runtime config rejects invalid upstream secret keys safely" do
    invalid_key = "too-short"
    env = Map.put(@required_env, "CODEX_POOLER_UPSTREAM_SECRET_KEY", invalid_key)

    with_env(env, fn ->
      error =
        assert_raise RuntimeError, fn ->
          Config.Reader.read!("config/runtime.exs", env: :prod)
        end

      assert Exception.message(error) ==
               "CODEX_POOLER_UPSTREAM_SECRET_KEY must be 32 raw bytes or base64-encoded 32 bytes"

      refute Exception.message(error) =~ invalid_key
    end)
  end

  defp with_env(env, fun) do
    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
