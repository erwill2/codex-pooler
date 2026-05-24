defmodule CodexPooler.Platform.DNSClusterResolverTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Platform.DNSClusterResolver

  describe "reject_current_pod_ip/1" do
    test "removes only the current pod IPv4 record" do
      with_pod_ip("10.42.0.130", fn ->
        assert DNSClusterResolver.reject_current_pod_ip([
                 {10, 42, 0, 130},
                 {10, 42, 0, 127}
               ]) == [{10, 42, 0, 127}]
      end)
    end

    test "preserves records when POD_IP is missing" do
      records = [{10, 42, 0, 130}]

      with_pod_ip(nil, fn ->
        assert DNSClusterResolver.reject_current_pod_ip(records) == records
      end)
    end
  end

  defp with_pod_ip(value, fun) do
    previous = System.get_env("POD_IP")

    if value do
      System.put_env("POD_IP", value)
    else
      System.delete_env("POD_IP")
    end

    try do
      fun.()
    after
      if previous do
        System.put_env("POD_IP", previous)
      else
        System.delete_env("POD_IP")
      end
    end
  end
end
