defmodule CodexPooler.Accounting.APIKeyPolicyReservationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  describe "api key policy reservation enforcement" do
    test "weekly token limit uses conservative reservation instead of tiny output cap" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_tokens_per_week: 100,
        max_requests_per_minute: 60,
        max_tokens_per_day: 1_000
      })

      consumed_request = request_fixture(setup.auth, %{model_id: setup.model.id})

      ledger_entry_fixture(consumed_request, %{
        pricing_snapshot_id: setup.pricing.id,
        total_tokens: 90,
        input_tokens: 90,
        output_tokens: 0,
        estimated_cost_micros: 900,
        settled_cost_micros: 900
      })

      assert {:error, error} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-weekly-token-denied"}
               )

      assert error.code == :api_key_policy_limit_exceeded
      assert error.message =~ "max_tokens_per_week"

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where:
                   e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation" and
                     e.amount_status == "recorded"
               ),
               :count
             ) == 0

      refute Repo.get_by(CodexPooler.Accounting.Request,
               correlation_id: "corr-weekly-token-denied"
             )
    end

    test "missing output cap reserves conservative default output pressure" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-missing-output-cap"}
               )

      assert reserved.estimate.output_tokens == 512
      assert reserved.estimate.total_tokens == 512
      assert reserved.reservation.output_tokens == 512
      assert reserved.request.request_metadata["reservation"]["output_tokens"] == 512
    end

    test "continuation payload reserves opaque context conservatively" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "previous_response_id" => "resp_synthetic_continuation",
                   "max_output_tokens" => 10
                 },
                 %{correlation_id: "corr-continuation-conservative"}
               )

      assert reserved.estimate.output_tokens == 2_048
      assert reserved.estimate.total_tokens > 2_048
      assert reserved.reservation.output_tokens == 2_048
    end

    test "unknown final usage settles from conservative reservation" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-unknown-conservative"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 last_error_code: "stream_interrupted",
                 usage: %{status: "usage_unknown"}
               })

      assert reserved.estimate.output_tokens == 512
      assert result.settlement.usage_status == "usage_unknown"
      assert result.settlement.output_tokens == reserved.reservation.output_tokens
      assert result.settlement.total_tokens == reserved.reservation.total_tokens
      assert result.settlement.details["estimated_from_reserve"] == true
    end

    test "concurrent token reservations near limit cannot oversubscribe with tiny caps" do
      setup = accounting_setup()
      parent = self()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 512,
        max_tokens_per_week: 10_000
      })

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Accounting.reserve(
              setup.auth,
              setup.model,
              %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
              %{correlation_id: "corr-concurrent-token-limit-#{index}"}
            )
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.count(results, &match?({:ok, _reserved}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, %{code: :api_key_policy_limit_exceeded}}, &1)
             ) == 1

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where:
                   e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation" and
                     e.amount_status == "recorded"
               ),
               :count
             ) == 1
    end

    test "concurrent request limits serialize so two over-limit reservations cannot both succeed" do
      setup = accounting_setup()
      parent = self()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 1,
        max_tokens_per_day: 1_000,
        max_tokens_per_week: 10_000
      })

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Accounting.reserve(
              setup.auth,
              setup.model,
              %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
              %{correlation_id: "corr-concurrent-limit-#{index}"}
            )
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.count(results, &match?({:ok, _reserved}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, %{code: :api_key_policy_limit_exceeded}}, &1)
             ) == 1

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where:
                   e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation" and
                     e.amount_status == "recorded"
               ),
               :count
             ) == 1
    end
  end
end
