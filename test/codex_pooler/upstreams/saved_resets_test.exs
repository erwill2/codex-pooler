defmodule CodexPooler.Upstreams.SavedResetsTest do
  use CodexPooler.DataCase, async: true

  alias CodexPooler.Upstreams.SavedResets

  describe "count_from_usage_payload/1" do
    test "parses reported saved reset counts" do
      assert {:reported, 2} =
               SavedResets.count_from_usage_payload(%{
                 "rate_limit_reset_credits" => %{"available_count" => 2}
               })

      assert %{label: "2 saved resets", available?: true, reported?: true} =
               %{
                 "saved_resets" =>
                   SavedResets.usage_snapshot(
                     %{"rate_limit_reset_credits" => %{"available_count" => 2}},
                     DateTime.utc_now(),
                     "https://chatgpt.com/wham/usage"
                   )
               }
               |> SavedResets.snapshot()
    end

    test "projects sanitized reset credit expirations" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      snapshot =
        %{
          "saved_resets" =>
            SavedResets.usage_snapshot(
              %{
                "rate_limit_reset_credits" => %{
                  "available_count" => 2,
                  "credits" => [
                    %{
                      "id" => "ignored-late",
                      "status" => "available",
                      "expires_at" => "2026-07-20T00:40:11.968726Z"
                    },
                    %{
                      "id" => "ignored-redeemed",
                      "status" => "redeemed",
                      "expires_at" => "2026-07-18T00:40:11.968726Z"
                    },
                    %{
                      "id" => "ignored-early",
                      "status" => "available",
                      "expires_at" => "2026-07-18T00:40:11.968726Z"
                    }
                  ]
                }
              },
              observed_at,
              "https://chatgpt.com/backend-api/wham/usage"
            )
        }
        |> SavedResets.snapshot()

      assert snapshot.available_expires_at == [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ]

      assert snapshot.next_expires_at == "2026-07-18T00:40:11.968726Z"
      assert snapshot.expires_reported? == true
    end

    test "clamps negative counts to zero" do
      assert {:reported, 0} =
               SavedResets.count_from_usage_payload(%{
                 "rate_limit_reset_credits" => %{"available_count" => -1}
               })

      assert %{label: "No saved resets", available?: false, reported?: true} =
               %{
                 "saved_resets" =>
                   SavedResets.usage_snapshot(
                     %{"rate_limit_reset_credits" => %{"available_count" => -1}},
                     DateTime.utc_now(),
                     "https://chatgpt.com/wham/usage"
                   )
               }
               |> SavedResets.snapshot()
    end

    test "returns unreported when the block is missing" do
      assert :unreported = SavedResets.count_from_usage_payload(%{})

      assert %{label: "Saved resets not reported", available?: false, reported?: false} =
               %{"saved_resets" => SavedResets.usage_snapshot(%{}, DateTime.utc_now(), nil)}
               |> SavedResets.snapshot()
    end

    test "projects in-progress redemption metadata" do
      assert %{in_progress?: true} =
               SavedResets.snapshot(%{
                 "saved_resets" => %{
                   "status" => "reported",
                   "available_count" => 1,
                   "source" => "codex_usage_api",
                   "path_style" => "chatgpt_api",
                   "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                   "usage_path" => "/wham/usage",
                   "reason" => nil
                 },
                 "saved_reset_redemption" => %{"status" => "redeeming"}
               })
    end
  end
end
