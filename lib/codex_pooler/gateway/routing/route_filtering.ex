defmodule CodexPooler.Gateway.Routing.RouteFiltering do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.{Executor, Plan}

  @type candidate :: CandidateEligibility.FilterInput.candidate()
  @type gateway_error :: Contracts.gateway_error()
  @type quota_mode :: :required | :optional

  @spec filter_candidates(CandidateEligibility.FilterInput.t()) ::
          {:ok, [candidate()], RequestOptions.t()} | {:error, gateway_error()}
  @spec filter_candidates(CandidateEligibility.FilterInput.t(), keyword()) ::
          {:ok, [candidate()], RequestOptions.t()} | {:error, gateway_error()}
  def filter_candidates(filter_input, opts \\ [])

  def filter_candidates(%CandidateEligibility.FilterInput{} = filter_input, opts)
      when is_list(opts) do
    request_options = filter_input.request_options
    quota_mode = Keyword.get(opts, :quota_mode, :required)

    with {:ok, candidates, quota_decision} <-
           filter_quota_eligible_candidates(filter_input, quota_mode),
         request_options = put_quota_decision(request_options, quota_decision),
         filter_input =
           filter_input
           |> CandidateEligibility.FilterInput.put_candidates(candidates)
           |> CandidateEligibility.FilterInput.put_request_options(request_options),
         {:ok, candidates} <-
           CandidateEligibility.filter_circuit_eligible_candidates(filter_input) do
      {:ok, candidates, request_options}
    end
  end

  defp filter_quota_eligible_candidates(
         %CandidateEligibility.FilterInput{} = filter_input,
         quota_mode
       ) do
    case Plan.filter_eligible_candidates(filter_input) do
      {:refreshable_quota, refresh_plan} ->
        refresh_plan
        |> Executor.refresh_stale_candidates()
        |> maybe_allow_missing_quota(filter_input, quota_mode)

      result ->
        maybe_allow_missing_quota(result, filter_input, quota_mode)
    end
  end

  defp maybe_allow_missing_quota(
         {:error, %{code: code}},
         %CandidateEligibility.FilterInput{} = filter_input,
         :optional
       )
       when code in ["quota_evidence_unavailable", :quota_evidence_unavailable] do
    {:ok, filter_input.candidates, nil}
  end

  defp maybe_allow_missing_quota(result, _filter_input, _quota_mode), do: result

  defp put_quota_decision(%RequestOptions{} = request_options, nil), do: request_options

  defp put_quota_decision(%RequestOptions{} = request_options, quota_decision),
    do: RequestOptions.put_routing(request_options, quota_decision: quota_decision)
end
