defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStore do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()

  @spec evidence_changeset(identity_ref(), map(), DateTime.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, Evidence.errors() | map()}
  def evidence_changeset(identity_or_id, attrs, observed_at) do
    with {:ok, evidence} <- Evidence.new(attrs, observed_at),
         identity_id when is_binary(identity_id) <- evidence_identity_id(identity_or_id, attrs) do
      %Quota.AccountQuotaWindow{}
      |> Quota.AccountQuotaWindow.changeset(
        evidence
        |> Evidence.to_window_attrs()
        |> Map.put(:upstream_identity_id, identity_id)
        |> put_timestamps()
      )
      |> then(&{:ok, &1})
    else
      {:error, _errors} = error -> error
      _missing_identity -> {:error, %{upstream_identity_id: ["can't be blank"]}}
    end
  end

  @spec record_evidence(identity_ref(), map(), DateTime.t()) ::
          {:ok, Quota.AccountQuotaWindow.t()}
          | {:error, Ecto.Changeset.t() | Evidence.errors() | map()}
  def record_evidence(identity_or_id, attrs, observed_at) do
    with {:ok, evidence} <- Evidence.new(attrs, observed_at),
         identity_id when is_binary(identity_id) <- evidence_identity_id(identity_or_id, attrs) do
      attrs =
        evidence
        |> Evidence.to_window_attrs()
        |> Map.put(:upstream_identity_id, identity_id)

      existing = get_existing_evidence(identity_id, evidence)
      timestamped_attrs = merge_attrs(existing, attrs, evidence)

      existing
      |> Quota.AccountQuotaWindow.changeset(timestamped_attrs)
      |> Repo.insert_or_update()
    else
      {:error, _errors} = error -> error
      _missing_identity -> {:error, %{upstream_identity_id: ["can't be blank"]}}
    end
  end

  @spec list_evidence(identity_ref()) :: [Quota.AccountQuotaWindow.t()]
  def list_evidence(identity_or_id) do
    case evidence_identity_id(identity_or_id, %{}) do
      identity_id when is_binary(identity_id) ->
        Repo.all(
          from window in Quota.AccountQuotaWindow,
            where: window.upstream_identity_id == ^identity_id,
            order_by: [
              asc: window.quota_scope,
              asc: window.quota_family,
              asc: window.quota_key,
              asc: window.window_kind,
              desc: window.merge_precedence,
              desc: window.observed_at
            ]
        )

      nil ->
        []
    end
  end

  defp get_existing_evidence(identity_id, %Evidence{} = evidence) do
    exact_existing_evidence(identity_id, evidence) ||
      alias_existing_evidence(identity_id, evidence) ||
      fallback_existing_evidence(identity_id, evidence) ||
      %Quota.AccountQuotaWindow{}
  end

  defp exact_existing_evidence(identity_id, %Evidence{} = evidence) do
    Repo.one(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.quota_scope == ^evidence.quota_scope,
        where: window.quota_family == ^evidence.quota_family,
        where: fragment("COALESCE(lower(?), '')", window.model) == ^lower_string(evidence.model),
        where:
          fragment("COALESCE(lower(?), '')", window.upstream_model) ==
            ^lower_string(evidence.upstream_model),
        where: window.quota_key == ^evidence.quota_key,
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        order_by: [desc: window.merge_precedence, desc: window.observed_at],
        limit: 1
    )
  end

  defp alias_existing_evidence(identity_id, %Evidence{quota_key: "codex_spark"} = evidence) do
    Repo.one(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.quota_key in ["gpt_5_3_codex_spark", "codex_bengalfox", "codex_other"],
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        where: window.source == ^evidence.source,
        order_by: [desc: window.merge_precedence, desc: window.observed_at],
        limit: 1
    )
  end

  defp alias_existing_evidence(_identity_id, _evidence), do: nil

  defp fallback_existing_evidence(identity_id, %Evidence{} = evidence) do
    Repo.one(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.quota_key == ^evidence.quota_key,
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        order_by: [desc: window.merge_precedence, desc: window.observed_at],
        limit: 1
    )
  end

  defp merge_attrs(%Quota.AccountQuotaWindow{id: nil} = existing, attrs, _evidence),
    do: put_timestamps(attrs, existing)

  defp merge_attrs(%Quota.AccountQuotaWindow{} = existing, attrs, %Evidence{} = evidence) do
    timestamp = now()

    if incoming_supersedes?(evidence, existing, timestamp) do
      put_timestamps(attrs, existing)
    else
      existing
      |> Map.from_struct()
      |> Map.take(Quota.AccountQuotaWindow.__schema__(:fields))
      |> Map.put(:updated_at, timestamp)
    end
  end

  defp incoming_supersedes?(
         %Evidence{} = evidence,
         %Quota.AccountQuotaWindow{} = existing,
         timestamp
       ) do
    incoming_quality = quality_key(evidence, timestamp)
    existing_quality = quality_key(existing, timestamp)

    resetless_weekly_rate_limit_supersedes?(evidence, existing) ||
      incoming_quality >= existing_quality
  end

  defp resetless_weekly_rate_limit_supersedes?(
         %Evidence{
           source: "codex_rate_limit_event",
           window_minutes: 10_080,
           observed_at: %DateTime{} = observed_at
         } = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_rate_limit_event",
           window_minutes: 10_080,
           observed_at: %DateTime{} = existing_observed_at
         } = existing
       ) do
    not Evidence.reset_bearing?(evidence) and
      DateTime.compare(observed_at, existing_observed_at) != :lt and
      same_evidence_identity?(evidence, existing)
  end

  defp resetless_weekly_rate_limit_supersedes?(_evidence, _existing), do: false

  defp same_evidence_identity?(%Evidence{} = evidence, %Quota.AccountQuotaWindow{} = existing) do
    evidence.quota_scope == existing.quota_scope and
      evidence.quota_family == existing.quota_family and
      evidence.quota_key == existing.quota_key and evidence.window_kind == existing.window_kind and
      lower_string(evidence.model) == lower_string(existing.model) and
      lower_string(evidence.upstream_model) == lower_string(existing.upstream_model)
  end

  defp quality_key(evidence_or_window, timestamp) do
    {
      freshness_rank(Evidence.current_freshness_state(evidence_or_window, timestamp)),
      reset_rank(Evidence.reset_bearing?(evidence_or_window)),
      merge_precedence(evidence_or_window),
      observed_rank(evidence_or_window)
    }
  end

  defp freshness_rank("fresh"), do: 2
  defp freshness_rank("stale"), do: 1
  defp freshness_rank(_state), do: 0

  defp reset_rank(true), do: 1
  defp reset_rank(false), do: 0

  defp merge_precedence(%Evidence{} = evidence), do: evidence.merge_precedence || 0

  defp merge_precedence(%Quota.AccountQuotaWindow{merge_precedence: precedence}),
    do: precedence || 0

  defp observed_rank(%Evidence{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_rank(%Quota.AccountQuotaWindow{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_rank(_evidence_or_window), do: 0

  defp evidence_identity_id(%UpstreamIdentity{id: id}, _attrs), do: id
  defp evidence_identity_id(id, _attrs) when is_binary(id), do: id

  defp evidence_identity_id(_identity_or_id, attrs),
    do: Map.get(attrs, :upstream_identity_id) || Map.get(attrs, "upstream_identity_id")

  defp lower_string(value) when is_binary(value), do: String.downcase(value)
  defp lower_string(_value), do: ""

  defp put_timestamps(attrs, existing \\ %Quota.AccountQuotaWindow{}) do
    timestamp = now()

    attrs
    |> Map.put_new(:created_at, existing.created_at || timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
