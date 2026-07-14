defmodule CodexPooler.Gateway.Runtime.ModelUnavailableTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.ModelUnavailable
  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @endpoint "/backend-api/codex/responses"

  setup do
    assignment_id = Ecto.UUID.generate()

    context =
      selected_context(assignment_id,
        source_assignment_ids: [assignment_id]
      )

    %{context: context}
  end

  describe "http_error?/3" do
    test "recognizes explicit model_not_found codes", %{context: context} do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "model_not_found",
            "message" => "model is not installed",
            "type" => "invalid_request_error"
          }
        })

      assert ModelUnavailable.http_error?(400, body, context)
      assert ModelUnavailable.http_error?(404, body, context)
    end

    test "recognizes ambiguous 404 model errors only with catalog provenance", %{
      context: context
    } do
      body =
        Jason.encode!(%{
          "error" => %{
            "type" => "invalid_request_error",
            "param" => "model",
            "message" => "model is not available for this account"
          }
        })

      assert ModelUnavailable.http_error?(404, body, context)
      refute ModelUnavailable.http_error?(400, body, context)

      without_provenance =
        selected_context(context.assignment.id,
          source_assignment_ids: [Ecto.UUID.generate()]
        )

      refute ModelUnavailable.http_error?(404, body, without_provenance)
    end

    test "does not reclassify unrelated or malformed errors", %{context: context} do
      unrelated =
        Jason.encode!(%{
          "error" => %{"type" => "invalid_request_error", "param" => "input"}
        })

      conflicting_code =
        Jason.encode!(%{
          "error" => %{
            "code" => "unrelated_invalid_request",
            "type" => "invalid_request_error",
            "param" => "model"
          }
        })

      refute ModelUnavailable.http_error?(404, unrelated, context)
      refute ModelUnavailable.http_error?(404, conflicting_code, context)
      refute ModelUnavailable.http_error?(404, "not-json", context)
    end
  end

  describe "retry policy" do
    test "allows explicit model failures when another candidate is available", %{context: context} do
      assert ModelUnavailable.retryable_failure?(model_not_found_failure(), context)
    end

    test "requires provenance for ambiguous invalid-request model failures", %{
      context: context
    } do
      failure = invalid_request_model_failure()
      assert ModelUnavailable.retryable_failure?(failure, context)

      without_provenance =
        selected_context(context.assignment.id,
          source_assignment_ids: [Ecto.UUID.generate()]
        )

      refute ModelUnavailable.retryable_failure?(failure, without_provenance)
      assert ModelUnavailable.failure_signature?(failure)
    end

    test "blocks exhausted, compact, and hard-pinned failover", %{context: context} do
      refute ModelUnavailable.retryable_failure?(
               model_not_found_failure(),
               %{context | allow_retry?: false}
             )

      refute ModelUnavailable.retryable_failure?(
               model_not_found_failure(),
               %{context | endpoint: "/backend-api/codex/responses/compact"}
             )

      hard_pinned_options =
        RequestOptions.build(
          %{previous_response_id: "resp_hard_pin"},
          @endpoint,
          %{"model" => "synthetic-model", "previous_response_id" => "resp_hard_pin"}
        )

      refute ModelUnavailable.retryable_failure?(
               model_not_found_failure(),
               %{context | request_options: hard_pinned_options}
             )
    end
  end

  describe "first-event SSE classification" do
    test "retries model_not_found before downstream-visible output", %{context: context} do
      data = terminal_sse("model_not_found", nil)

      assert {{:retry, %{code: "model_not_found"}}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 data,
                 StreamAttempt.first_event_state(),
                 context
               )
    end

    test "retries provenance-backed invalid_request_error for the model parameter", %{
      context: context
    } do
      data = terminal_sse("invalid_request_error", "model")

      assert {{:retry, %{upstream_error_param: "model"}}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 data,
                 StreamAttempt.first_event_state(),
                 context
               )
    end

    test "writes ambiguous model errors when provenance is absent", %{context: context} do
      context =
        selected_context(context.assignment.id,
          source_assignment_ids: [Ecto.UUID.generate()]
        )

      data = terminal_sse("invalid_request_error", "model")

      assert {{:write_terminal_failure, ^data, %{code: "invalid_request_error"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 data,
                 StreamAttempt.first_event_state(),
                 context
               )
    end
  end

  defp selected_context(assignment_id, opts) do
    request_options = RequestOptions.build(%{}, @endpoint, %{"model" => "synthetic-model"})

    %SelectedCandidateContext{
      assignment: %PoolUpstreamAssignment{id: assignment_id},
      model: %Model{
        exposed_model_id: "synthetic-model",
        metadata: %{"source_assignment_ids" => Keyword.fetch!(opts, :source_assignment_ids)}
      },
      endpoint: @endpoint,
      request_options: request_options,
      allow_retry?: true
    }
  end

  defp model_not_found_failure do
    %{
      code: "model_not_found",
      upstream_code: "model_not_found",
      upstream_error_param: nil
    }
  end

  defp invalid_request_model_failure do
    %{
      code: "invalid_request_error",
      upstream_code: "invalid_request_error",
      upstream_error_param: "model"
    }
  end

  defp terminal_sse(code, param) do
    error = %{"code" => code} |> maybe_put("param", param)

    "event: response.failed\n" <>
      "data: #{Jason.encode!(%{"type" => "response.failed", "response" => %{"error" => error}})}\n\n"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
