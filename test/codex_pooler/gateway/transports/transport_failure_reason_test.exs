defmodule CodexPooler.Gateway.Transports.TransportFailureReasonTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.TransportFailureReason

  test "extracts safe reasons from transport exceptions" do
    assert TransportFailureReason.safe_reason(%Req.TransportError{reason: :timeout}) == "timeout"

    assert TransportFailureReason.safe_reason(%Finch.TransportError{
             reason: :closed,
             source: %Mint.TransportError{reason: :econnrefused}
           }) == "econnrefused"

    assert TransportFailureReason.safe_reason(%Finch.HTTPError{
             reason: :closed,
             source: %Mint.HTTPError{reason: {:proxy, {:unexpected_status, 503}}}
           }) == "proxy_unexpected_status_503"
  end

  test "normalizes tuple reasons without inspecting full terms" do
    assert TransportFailureReason.safe_reason({:tls_alert, {:unknown_ca, %{cert: "hidden"}}}) ==
             "tls_alert_unknown_ca"

    assert TransportFailureReason.safe_reason({:bad_alpn_protocol, :http1}) ==
             "bad_alpn_protocol_http1"

    assert TransportFailureReason.safe_reason({:upstream_status, 503, %{body: "hidden"}}) ==
             "upstream_status_503"
  end

  test "normalizes blank and long string reasons" do
    assert TransportFailureReason.safe_reason(" !!! ") == nil

    assert TransportFailureReason.safe_reason(%Req.TransportError{reason: "Gateway Timeout!"}) ==
             "gateway_timeout"

    assert TransportFailureReason.safe_reason(String.duplicate("A", 120)) ==
             String.duplicate("a", 96)
  end

  test "returns only exception module names" do
    assert TransportFailureReason.safe_exception(%Req.TransportError{reason: :timeout}) ==
             "Req.TransportError"

    assert TransportFailureReason.safe_exception(:timeout) == nil
  end

  test "builds compact allowlisted transport failure metadata" do
    metadata =
      TransportFailureReason.transport_failure_metadata(
        %Mint.TransportError{reason: :closed},
        %{
          phase: :receive,
          pre_visible_output: false,
          terminal_seen: false,
          text_frame_count: 1
        }
      )

    assert metadata == %{
             "exception" => "Mint.TransportError",
             "reason" => "closed",
             "reason_class" => "Mint.TransportError",
             "phase" => "receive",
             "pre_visible_output" => false,
             "terminal_seen" => false,
             "text_frame_count" => 1
           }
  end

  test "transport failure metadata does not persist arbitrary binary reasons" do
    metadata =
      TransportFailureReason.transport_failure_metadata(
        "raw reason with token-like value secret-bearer-value",
        %{phase: "send payload", pre_visible_output: true}
      )

    assert metadata == %{
             "phase" => "send_payload",
             "pre_visible_output" => true,
             "reason_class" => "binary"
           }
  end
end
