defmodule CodexPooler.Gateway.Payloads.TransportEnvelopeTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Payloads.TransportEnvelope

  describe "timeout_config/2" do
    test "returns the typed timeout config used by Req options" do
      options = request_options(%TimeoutConfig{pool_timeout_ms: 25, receive_timeout_ms: 50})

      defaults = %{connect_timeout_ms: 10, pool_timeout_ms: 20, receive_timeout_ms: 30}

      assert %TimeoutConfig{
               connect_timeout_ms: 10,
               pool_timeout_ms: 25,
               receive_timeout_ms: 50
             } = TransportEnvelope.timeout_config(options, defaults)
    end
  end

  describe "req_timeout_options/1" do
    test "maps timeout config fields to Req option names" do
      timeouts = %TimeoutConfig{
        connect_timeout_ms: 10,
        pool_timeout_ms: 20,
        receive_timeout_ms: 30
      }

      assert TransportEnvelope.req_timeout_options(timeouts) == [
               receive_timeout: 30,
               pool_timeout: 20,
               connect_options: [timeout: 10]
             ]
    end
  end

  defp request_options(%TimeoutConfig{} = timeout_config) do
    %RequestOptions{
      request_metadata: nil,
      transport: nil,
      continuity: nil,
      routing: nil,
      timeout_config: timeout_config,
      payload_context: nil,
      runtime: nil,
      openai_compatibility: nil,
      usage_authentication: nil,
      file_bridge: nil
    }
  end
end
