defmodule CodexPooler.Upstreams.EndpointMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  describe "base_url/3" do
    test "prefers assignment metadata before identity metadata and default" do
      identity = identity(%{"base_url" => "https://identity.example.com"})
      assignment = assignment(%{"api_base_url" => "https://assignment.example.com/backend-api"})

      assert EndpointMetadata.base_url(identity, assignment) ==
               "https://assignment.example.com/backend-api"

      assert EndpointMetadata.endpoint_url(identity, assignment, "/backend-api/codex/responses") ==
               {:ok, "https://assignment.example.com/backend-api/codex/responses"}
    end

    test "falls back through identity metadata and caller default" do
      assert EndpointMetadata.base_url(
               identity(%{"upstream_base_url" => "https://identity.example.com"}),
               assignment(%{})
             ) == "https://identity.example.com"

      assert EndpointMetadata.base_url(identity(%{}), assignment(%{}), nil) == nil

      assert EndpointMetadata.endpoint_url(
               identity(%{}),
               assignment(%{}),
               "/api/codex/usage",
               nil
             ) == {:error, :invalid_upstream_base_url}
    end
  end

  describe "usage_base_url/3" do
    test "keeps usage-specific metadata ahead of generic base url metadata" do
      identity =
        identity(%{
          "usage_base_url" => "https://identity-usage.example.com",
          "base_url" => "https://identity-generic.example.com"
        })

      assignment =
        assignment(%{
          "codex_usage_base_url" => "https://assignment-usage.example.com",
          "base_url" => "https://assignment-generic.example.com"
        })

      assert EndpointMetadata.usage_base_url(identity, assignment) ==
               "https://assignment-usage.example.com"
    end
  end

  defp identity(metadata), do: %UpstreamIdentity{metadata: metadata}
  defp assignment(metadata), do: %PoolUpstreamAssignment{metadata: metadata}
end
