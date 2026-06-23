defmodule CodexPooler.Upstreams.SavedResetReconciliationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets

  test "refresh_quota_from_usage stores sanitized saved reset usage snapshot" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {404, %{}},
           "/backend-api/codex/usage" => {404, %{}},
           "/wham/usage" => {404, %{}},
           "/backend-api/wham/usage" => {200, usage_payload(3)}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)

    assert %{
             status: "reported",
             available_count: 3,
             available?: true,
             reported?: true,
             path_style: "chatgpt_api",
             usage_path: "/backend-api/wham/usage"
           } = SavedResets.snapshot(updated_identity)

    assert get_in(updated_identity.metadata, ["saved_resets", "source"]) == "codex_usage_api"
    assert is_binary(get_in(updated_identity.metadata, ["saved_resets", "observed_at"]))

    metadata_json = Jason.encode!(updated_identity.metadata)
    refute metadata_json =~ "credits"
    refute metadata_json =~ "credit_id"
    refute metadata_json =~ "redeem_request_id"
  end

  test "refresh_quota_from_usage stores unreported snapshot when usage omits reset credits" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, Map.delete(usage_payload(1), "rate_limit_reset_credits")}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             status: "unreported",
             available_count: nil,
             available?: false,
             reported?: false,
             usage_path: "/api/codex/usage"
           } = SavedResets.snapshot(Repo.reload!(updated_identity))
  end

  defp usage_payload(available_count) do
    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => available_count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      }
    }
  end
end
