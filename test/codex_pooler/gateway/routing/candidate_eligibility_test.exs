defmodule CodexPooler.Gateway.Routing.CandidateEligibilityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput

  describe "filter_runtime_compatible_candidates/1" do
    test "auto and default do not narrow the candidate set" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "default"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported", "assignment-plain"]

      auto_payload = Map.put(payload, "service_tier", "auto")

      auto_request_options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", auto_payload)

      assert {:ok, auto_filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, auto_payload, auto_request_options, candidates)
               )

      assert candidate_ids(auto_filtered) == ["assignment-supported", "assignment-plain"]
    end

    test "a concrete supported tier narrows to candidates that explicitly advertise it" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "priority"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported"]
    end

    test "a concrete unsupported tier produces no compatible backend" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "ultrafast"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:error, %{code: "no_compatible_backend"}} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )
    end

    test "a concrete tier excludes source assignments missing per-assignment metadata" do
      model = model_missing_assignment_metadata("assignment-missing")
      candidates = [candidate("assignment-missing")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "ultrafast"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:error, %{code: "no_compatible_backend"}} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )
    end

    test "missing per-assignment metadata remains compatible without a concrete tier" do
      model = model_missing_assignment_metadata("assignment-missing")
      candidates = [candidate("assignment-missing")]
      payload = %{"model" => "gpt-4.1", "input" => "hello"}

      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-missing"]
    end

    test "auto and default keep source assignments compatible without per-assignment metadata" do
      model = model_missing_assignment_metadata("assignment-missing")
      candidates = [candidate("assignment-missing")]

      for tier <- ["auto", "default"] do
        payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => tier}
        request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

        assert {:ok, filtered} =
                 CandidateEligibility.filter_runtime_compatible_candidates(
                   filter_input(model, payload, request_options, candidates)
                 )

        assert candidate_ids(filtered) == ["assignment-missing"]
      end
    end

    test "an api-key enforced tier overrides the client payload tier" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "default"}

      request_options =
        RequestOptions.build(
          %{api_key_policy: %{enforced_service_tier: "priority"}},
          "/backend-api/codex/responses",
          payload
        )

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported"]
    end

    test "an api-key enforced default tier overrides a concrete client payload tier" do
      model = model_with_tier_support("assignment-supported", "priority")
      candidates = [candidate("assignment-supported"), candidate("assignment-plain")]
      payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "priority"}

      request_options =
        RequestOptions.build(
          %{api_key_policy: %{enforced_service_tier: "default"}},
          "/backend-api/codex/responses",
          payload
        )

      assert {:ok, filtered} =
               CandidateEligibility.filter_runtime_compatible_candidates(
                 filter_input(model, payload, request_options, candidates)
               )

      assert candidate_ids(filtered) == ["assignment-supported", "assignment-plain"]
    end
  end

  defp candidate(assignment_id) do
    {%{id: assignment_id, metadata: %{}}, %{id: "#{assignment_id}-identity", metadata: %{}}}
  end

  defp candidate_ids(candidates),
    do: Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)

  defp filter_input(model, payload, request_options, candidates) do
    FilterInput.new(%{
      model: model,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: request_options,
      candidates: candidates
    })
  end

  defp model_with_tier_support(supported_assignment_id, supported_tier) do
    %Model{
      metadata: %{
        "source_assignment_models" => %{
          supported_assignment_id => %{
            "capabilities" => %{"responses" => true},
            "service_tiers" => [
              %{"id" => supported_tier, "name" => supported_tier, "description" => supported_tier}
            ],
            "additional_speed_tiers" => []
          },
          "assignment-plain" => %{
            "capabilities" => %{"responses" => true},
            "service_tiers" => [],
            "additional_speed_tiers" => []
          }
        }
      }
    }
  end

  defp model_missing_assignment_metadata(assignment_id) do
    %Model{
      metadata: %{
        "source_assignment_ids" => [assignment_id],
        "source_assignment_models" => %{}
      }
    }
  end
end
