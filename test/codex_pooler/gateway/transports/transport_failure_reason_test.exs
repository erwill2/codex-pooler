defmodule CodexPooler.Gateway.Transports.TransportFailureReasonTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.TransportFailureReason

  test "extracts safe reasons from transport exceptions" do
    assert TransportFailureReason.safe_reason(%Req.TransportError{reason: :timeout}) == "timeout"

    assert TransportFailureReason.safe_reason(%Finch.TransportError{
             reason: :closed,
             source: %Mint.TransportError{reason: :econnrefused}
           }) == "econnrefused"
  end

  test "normalizes tuple reasons without inspecting full terms" do
    assert TransportFailureReason.safe_reason({:tls_alert, {:unknown_ca, %{cert: "hidden"}}}) ==
             "tls_alert_unknown_ca"

    assert TransportFailureReason.safe_reason({:bad_alpn_protocol, :http1}) ==
             "bad_alpn_protocol_http1"
  end

  test "returns only exception module names" do
    assert TransportFailureReason.safe_exception(%Req.TransportError{reason: :timeout}) ==
             "Req.TransportError"

    assert TransportFailureReason.safe_exception(:timeout) == nil
  end
end
