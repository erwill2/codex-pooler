defmodule CodexPooler.Quotas do
  @moduledoc """
  Context boundary for normalized quota evidence.

  This module parses quota evidence from upstream payloads and exposes value-level
  validation/routing helpers. Persistence belongs to `CodexPooler.Upstreams`.
  """

  alias CodexPooler.Quotas.Evidence
  @type evidence_error :: Evidence.errors()
  @type parser_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec normalize_evidence(term(), DateTime.t()) ::
          {:ok, Evidence.t()} | {:error, evidence_error()}
  def normalize_evidence(attrs, observed_at \\ now()), do: Evidence.new(attrs, observed_at)

  @spec parse_codex_usage_payload(term(), DateTime.t()) ::
          {:ok, [Evidence.t()]} | {:error, parser_error()}
  def parse_codex_usage_payload(payload, observed_at \\ now()),
    do: Evidence.parse_codex_usage_payload(payload, observed_at)

  @spec parse_codex_headers(term(), DateTime.t()) :: [Evidence.t()]
  def parse_codex_headers(headers, observed_at \\ now()),
    do: Evidence.parse_codex_headers(headers, observed_at)

  @spec parse_codex_rate_limit_event(term(), DateTime.t()) :: [Evidence.t()]
  def parse_codex_rate_limit_event(event, observed_at \\ now()),
    do: Evidence.parse_codex_rate_limit_event(event, observed_at)

  @spec parse_rate_limit_error(term(), DateTime.t()) :: [Evidence.t()]
  def parse_rate_limit_error(payload, observed_at \\ now()),
    do: Evidence.parse_rate_limit_error(payload, observed_at)

  @spec validate_evidence(term()) :: :ok | {:error, evidence_error()}
  def validate_evidence(attrs) do
    with {:ok, evidence} <- normalize_evidence(attrs) do
      Evidence.validate(evidence)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
