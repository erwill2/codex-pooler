defmodule CodexPooler.Jobs.ReadModel do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    HealthPolicy,
    TokenRefreshWorker
  }

  @admin_jobs_default_limit 15
  @admin_jobs_max_limit 50
  @explorer_page_size 50
  @completed_state "completed"
  @overview_action_buckets [:active_failure, :retry_pressure, :stuck_executing, :backlog_pressure]
  @hotspot_limit 5
  @hotspot_target_limit 6

  @type job_summary :: map()
  @type explorer_job_summary :: map()
  @type explorer_filters :: %{
          optional(:state) => String.t() | nil,
          optional(:worker) => String.t() | nil,
          optional(:queue) => String.t() | nil,
          optional(:attention) => String.t() | nil,
          optional(:target_kind) => String.t() | nil,
          optional(:target_id) => String.t() | nil,
          optional(:page) => pos_integer(),
          optional(:show_completed) => boolean()
        }
  @type explorer_page :: %{
          required(:items) => [explorer_job_summary()],
          required(:total) => non_neg_integer(),
          required(:limit) => pos_integer(),
          required(:offset) => non_neg_integer()
        }
  @type overview_status :: :attention_required | :healthy | :empty
  @type overview_bucket :: %{
          required(:count) => non_neg_integer(),
          required(:newest) => explorer_job_summary() | nil
        }
  @type jobs_overview :: %{
          required(:status) => overview_status(),
          required(:empty?) => boolean(),
          required(:healthy?) => boolean(),
          required(:total) => non_neg_integer(),
          required(:actionable_count) => non_neg_integer(),
          required(:completed_context_count) => non_neg_integer(),
          required(:buckets) => %{
            required(:active_failure) => overview_bucket(),
            required(:retry_pressure) => overview_bucket(),
            required(:stuck_executing) => overview_bucket(),
            required(:backlog_pressure) => overview_bucket()
          },
          required(:completed_context) => overview_bucket()
        }
  @type hotspot_count :: %{
          required(:count) => pos_integer(),
          required(:label) => String.t()
        }
  @type worker_hotspot :: %{
          required(:worker) => String.t(),
          required(:label) => String.t(),
          required(:count) => pos_integer()
        }
  @type queue_hotspot :: %{
          required(:queue) => String.t(),
          required(:label) => String.t(),
          required(:count) => pos_integer()
        }
  @type identified_hotspot :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:count) => pos_integer()
        }
  @type target_hotspot :: %{
          required(:kind) => atom(),
          required(:id) => String.t() | nil,
          required(:label) => String.t(),
          required(:count) => pos_integer()
        }
  @type jobs_hotspots :: %{
          required(:actionable_count) => non_neg_integer(),
          required(:workers) => [worker_hotspot()],
          required(:queues) => [queue_hotspot()],
          required(:pools) => [identified_hotspot()],
          required(:accounts) => [identified_hotspot()],
          required(:targets) => [target_hotspot()]
        }
  @type worker_job_summary :: %{
          latest: job_summary() | nil,
          latest_success: job_summary() | nil,
          latest_failure: job_summary() | nil,
          pending: job_summary() | nil,
          active: [job_summary()],
          unresolved_failures: [job_summary()]
        }
  @type scope_ref :: Scope.t() | :system | term()
  @type pool_ref :: Pool.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type identity_ref :: UpstreamIdentity.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()

  @spec list_system_jobs(keyword()) :: [job_summary()]
  def list_system_jobs(opts \\ []) do
    Oban.Job
    |> latest_jobs_query(opts)
    |> Repo.all()
    |> with_attention(opts)
  end

  @spec list_latest_jobs(scope_ref(), keyword()) :: [job_summary()]
  def list_latest_jobs(scope, opts \\ [])

  def list_latest_jobs(%Scope{} = scope, opts) do
    if Pools.owner?(scope), do: list_system_jobs(opts), else: []
  end

  def list_latest_jobs(:system, opts) do
    list_system_jobs(opts)
  end

  def list_latest_jobs(_scope, _opts), do: []

  @spec list_explorer_jobs(scope_ref(), explorer_filters(), keyword()) :: explorer_page()
  def list_explorer_jobs(scope, filters, opts \\ [])

  def list_explorer_jobs(%Scope{} = scope, filters, opts) do
    if Pools.owner?(scope),
      do: list_explorer_jobs(:system, filters, opts),
      else: empty_explorer_page(filters)
  end

  def list_explorer_jobs(:system, filters, opts) do
    filters = normalize_explorer_filters(filters)
    limit = @explorer_page_size
    offset = explorer_offset(filters.page, limit)

    query =
      Oban.Job
      |> apply_explorer_filters(filters)

    if filters.attention do
      attention_filtered_explorer_page(query, filters.attention, limit, offset, opts)
    else
      total = Repo.aggregate(query, :count, :id)

      items =
        query
        |> job_explorer_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()
        |> sanitize_explorer_error_summaries()
        |> with_attention(opts)

      %{items: items, total: total, limit: limit, offset: offset}
    end
  end

  def list_explorer_jobs(_scope, filters, _opts), do: empty_explorer_page(filters)

  @spec jobs_overview(scope_ref(), explorer_filters(), keyword()) :: jobs_overview()
  def jobs_overview(scope, filters, opts \\ [])

  def jobs_overview(%Scope{} = scope, filters, opts) do
    if Pools.owner?(scope),
      do: jobs_overview(:system, filters, opts),
      else: empty_jobs_overview()
  end

  def jobs_overview(:system, filters, opts) do
    filters = normalize_explorer_filters(filters)
    now = attention_now(opts)

    {:ok, overview} =
      Repo.transaction(fn ->
        Oban.Job
        |> apply_overview_filters(filters)
        |> job_explorer_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> Repo.stream()
        |> Enum.reduce(empty_jobs_overview(), &collect_overview_job(&1, &2, now))
        |> finalize_jobs_overview()
      end)

    overview
  end

  def jobs_overview(_scope, _filters, _opts), do: empty_jobs_overview()

  @spec jobs_hotspots(scope_ref(), explorer_filters(), keyword()) :: jobs_hotspots()
  def jobs_hotspots(scope, filters, opts \\ [])

  def jobs_hotspots(%Scope{} = scope, filters, opts) do
    if Pools.owner?(scope),
      do: jobs_hotspots(:system, filters, opts),
      else: empty_jobs_hotspots()
  end

  def jobs_hotspots(:system, filters, opts) do
    filters = normalize_explorer_filters(filters)
    now = attention_now(opts)

    {:ok, hotspots} =
      Repo.transaction(fn ->
        Oban.Job
        |> apply_overview_filters(filters)
        |> job_explorer_metadata_query()
        |> Repo.stream()
        |> Enum.reduce(empty_jobs_hotspots_accumulator(), &collect_hotspot_job(&1, &2, now))
        |> finalize_jobs_hotspots()
      end)

    hotspots
  end

  def jobs_hotspots(_scope, _filters, _opts), do: empty_jobs_hotspots()

  @spec worker_job_summary(scope_ref(), [String.t()]) :: worker_job_summary()
  def worker_job_summary(scope, workers)

  def worker_job_summary(_scope, []), do: empty_worker_job_summary()

  def worker_job_summary(%Scope{} = scope, workers) do
    if Pools.owner?(scope) do
      worker_job_summary(:system, workers)
    else
      empty_worker_job_summary()
    end
  end

  def worker_job_summary(:system, workers) do
    Oban.Job
    |> worker_job_summary_query(workers)
  end

  def worker_job_summary(_scope, _workers), do: empty_worker_job_summary()

  @spec list_recent_token_refresh_jobs(identity_ref(), keyword()) :: [job_summary()]
  def list_recent_token_refresh_jobs(identity_or_id, opts \\ []) do
    identity_id = identity_id(identity_or_id)
    limit = opts |> Keyword.get(:limit, 5) |> max(1) |> min(50)

    results =
      Repo.all(
        from job in Oban.Job,
          where:
            job.worker == ^worker_name(TokenRefreshWorker) and
              fragment("?->>?", job.args, "upstream_identity_id") == ^identity_id,
          order_by: [
            desc:
              fragment("COALESCE(?, ?, ?)", job.attempted_at, job.scheduled_at, job.inserted_at)
          ],
          limit: ^limit,
          select: %{
            id: job.id,
            state: job.state,
            worker: job.worker,
            queue: job.queue,
            args: job.args,
            errors: job.errors,
            attempt: job.attempt,
            max_attempts: job.max_attempts,
            inserted_at: job.inserted_at,
            scheduled_at: job.scheduled_at,
            attempted_at: job.attempted_at,
            completed_at: job.completed_at,
            discarded_at: job.discarded_at,
            cancelled_at: job.cancelled_at
          }
      )

    with_attention(results, opts)
  end

  @spec list_recent_account_reconciliation_jobs(pool_ref(), keyword()) :: [job_summary()]
  def list_recent_account_reconciliation_jobs(pool_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(50)

    results =
      Repo.all(
        from job in Oban.Job,
          where:
            job.worker == ^worker_name(AccountReconciliationWorker) and
              fragment("?->>?", job.args, "pool_id") == ^pool_id,
          order_by: [
            desc:
              fragment("COALESCE(?, ?, ?)", job.attempted_at, job.scheduled_at, job.inserted_at)
          ],
          limit: ^limit,
          select: %{
            id: job.id,
            state: job.state,
            worker: job.worker,
            queue: job.queue,
            args: job.args,
            errors: job.errors,
            attempt: job.attempt,
            max_attempts: job.max_attempts,
            inserted_at: job.inserted_at,
            scheduled_at: job.scheduled_at,
            attempted_at: job.attempted_at,
            completed_at: job.completed_at,
            discarded_at: job.discarded_at,
            cancelled_at: job.cancelled_at
          }
      )

    with_attention(results, opts)
  end

  defp where_worker_in(queryable, workers) do
    from job in queryable, where: job.worker in ^workers
  end

  defp worker_job_summary_query(queryable, workers) do
    queryable = where_worker_in(queryable, workers)

    %{
      latest: queryable |> latest_worker_job_query() |> Repo.one(),
      latest_success: queryable |> latest_worker_job_query(state: "completed") |> Repo.one(),
      latest_failure:
        queryable |> latest_worker_job_query(states: failure_states()) |> Repo.one(),
      pending: queryable |> next_pending_worker_job_query() |> Repo.one(),
      active: queryable |> active_worker_jobs_query() |> Repo.all(),
      unresolved_failures: queryable |> unresolved_failure_worker_jobs_query() |> Repo.all()
    }
    |> with_worker_summary_attention()
  end

  defp with_worker_summary_attention(summary) do
    now = DateTime.utc_now()

    %{
      summary
      | latest: with_attention(summary.latest, now: now),
        latest_success: with_attention(summary.latest_success, now: now),
        latest_failure: with_attention(summary.latest_failure, now: now),
        pending: with_attention(summary.pending, now: now),
        active: with_attention(summary.active, now: now),
        unresolved_failures: with_attention(summary.unresolved_failures, now: now)
    }
  end

  defp with_attention(jobs, opts) when is_list(jobs) do
    now = attention_now(opts)
    Enum.map(jobs, &HealthPolicy.put_attention(&1, now: now))
  end

  defp with_attention(nil, _opts), do: nil

  defp with_attention(job, opts) when is_map(job) do
    HealthPolicy.put_attention(job, now: attention_now(opts))
  end

  defp attention_now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp latest_worker_job_query(queryable, opts \\ []) do
    queryable
    |> maybe_where_states(opts)
    |> job_metadata_query()
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(1)
  end

  defp next_pending_worker_job_query(queryable) do
    queryable
    |> where([job], job.state in ^pending_states())
    |> job_metadata_query()
    |> order_by([job], asc: job.scheduled_at, desc: job.id)
    |> limit(1)
  end

  defp active_worker_jobs_query(queryable) do
    queryable
    |> where([job], job.state in ^pending_states())
    |> job_metadata_query()
    |> order_by([job], asc: job.scheduled_at, desc: job.id)
  end

  defp unresolved_failure_worker_jobs_query(queryable) do
    queryable
    |> where([job], job.state in ^failure_states())
    |> where(
      [job],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM oban_jobs resolved
          WHERE resolved.worker = ?
            AND resolved.state = 'completed'
            AND (
              resolved.inserted_at > ?
              OR (resolved.inserted_at = ? AND resolved.id > ?)
            )
            AND COALESCE(resolved.args->>'pool_id', '') = COALESCE(?->>'pool_id', '')
            AND COALESCE(resolved.args->>'pool_upstream_assignment_id', '') = COALESCE(?->>'pool_upstream_assignment_id', '')
            AND COALESCE(resolved.args->>'upstream_identity_id', '') = COALESCE(?->>'upstream_identity_id', '')
            AND COALESCE(resolved.args->>'api_key_id', '') = COALESCE(?->>'api_key_id', '')
            AND COALESCE(resolved.args->>'rollup_date', '') = COALESCE(?->>'rollup_date', '')
        )
        """,
        job.worker,
        job.inserted_at,
        job.inserted_at,
        job.id,
        job.args,
        job.args,
        job.args,
        job.args,
        job.args
      )
    )
    |> job_metadata_query()
    |> order_by([job], desc: job.inserted_at, desc: job.id)
  end

  defp maybe_where_states(queryable, state: state) do
    from job in queryable, where: job.state == ^state
  end

  defp maybe_where_states(queryable, states: states) do
    from job in queryable, where: job.state in ^states
  end

  defp maybe_where_states(queryable, _opts), do: queryable

  defp pending_states, do: ["available", "scheduled", "executing", "retryable"]
  defp failure_states, do: ["discarded", "retryable", "cancelled"]

  defp empty_worker_job_summary do
    %{
      latest: nil,
      latest_success: nil,
      latest_failure: nil,
      pending: nil,
      active: [],
      unresolved_failures: []
    }
  end

  defp latest_jobs_query(queryable, opts) do
    limit =
      opts
      |> Keyword.get(:limit, @admin_jobs_default_limit)
      |> max(1)
      |> min(@admin_jobs_max_limit)

    queryable
    |> job_metadata_query()
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(^limit)
  end

  defp empty_explorer_page(filters) do
    limit = @explorer_page_size

    offset =
      filters |> normalize_explorer_filters() |> Map.fetch!(:page) |> explorer_offset(limit)

    %{items: [], total: 0, limit: limit, offset: offset}
  end

  defp normalize_explorer_filters(filters) when is_map(filters) do
    %{
      state: filter_value(filters, :state),
      worker: filter_value(filters, :worker),
      queue: filter_value(filters, :queue),
      attention: filter_value(filters, :attention),
      target_kind: filter_value(filters, :target_kind),
      target_id: filter_value(filters, :target_id),
      page: normalized_page(filter_value(filters, :page)),
      show_completed: filter_value(filters, :show_completed) == true
    }
  end

  defp normalize_explorer_filters(_filters) do
    normalize_explorer_filters(%{})
  end

  defp filter_value(filters, key) do
    Map.get(filters, key) || Map.get(filters, Atom.to_string(key))
  end

  defp normalized_page(page) when is_integer(page) and page > 0, do: page
  defp normalized_page(_page), do: 1

  defp explorer_offset(page, limit), do: (page - 1) * limit

  defp apply_explorer_filters(queryable, filters) do
    queryable
    |> maybe_filter_explorer_completed_visibility(filters)
    |> maybe_filter_explorer_state(filters.state)
    |> maybe_filter_explorer_worker(filters.worker)
    |> maybe_filter_explorer_queue(filters.queue)
    |> maybe_filter_explorer_target(filters.target_kind, filters.target_id)
  end

  defp maybe_filter_explorer_completed_visibility(queryable, %{show_completed: true}),
    do: queryable

  defp maybe_filter_explorer_completed_visibility(queryable, %{state: @completed_state}),
    do: queryable

  defp maybe_filter_explorer_completed_visibility(queryable, _filters) do
    from job in queryable, where: job.state != @completed_state
  end

  defp maybe_filter_explorer_state(queryable, nil), do: queryable

  defp maybe_filter_explorer_state(queryable, state) do
    from job in queryable, where: job.state == ^state
  end

  defp maybe_filter_explorer_worker(queryable, nil), do: queryable

  defp maybe_filter_explorer_worker(queryable, worker) do
    from job in queryable, where: job.worker == ^worker
  end

  defp maybe_filter_explorer_queue(queryable, nil), do: queryable

  defp maybe_filter_explorer_queue(queryable, queue) do
    from job in queryable, where: job.queue == ^queue
  end

  defp maybe_filter_explorer_target(queryable, nil, _target_id), do: queryable

  defp maybe_filter_explorer_target(queryable, "assignment", target_id),
    do: where_arg(queryable, "pool_upstream_assignment_id", target_id)

  defp maybe_filter_explorer_target(queryable, "upstream_identity", target_id),
    do: where_arg(queryable, "upstream_identity_id", target_id)

  defp maybe_filter_explorer_target(queryable, "pool", target_id),
    do: where_arg(queryable, "pool_id", target_id)

  defp maybe_filter_explorer_target(queryable, "api_key", target_id),
    do: where_arg(queryable, "api_key_id", target_id)

  defp maybe_filter_explorer_target(queryable, "rollup_date", target_id),
    do: where_arg(queryable, "rollup_date", target_id)

  defp maybe_filter_explorer_target(queryable, "system", _target_id) do
    from job in queryable,
      where:
        is_nil(fragment("?->>?", job.args, "pool_id")) and
          is_nil(fragment("?->>?", job.args, "pool_upstream_assignment_id")) and
          is_nil(fragment("?->>?", job.args, "upstream_identity_id")) and
          is_nil(fragment("?->>?", job.args, "api_key_id")) and
          is_nil(fragment("?->>?", job.args, "rollup_date"))
  end

  defp maybe_filter_explorer_target(queryable, _target_kind, _target_id), do: queryable

  defp where_arg(queryable, _key, nil), do: queryable

  defp where_arg(queryable, key, value) do
    from job in queryable, where: fragment("?->>?", job.args, ^key) == ^value
  end

  defp empty_jobs_overview do
    %{
      status: :empty,
      empty?: true,
      healthy?: false,
      total: 0,
      actionable_count: 0,
      completed_context_count: 0,
      buckets: Map.new(@overview_action_buckets, &{&1, empty_overview_bucket()}),
      completed_context: empty_overview_bucket()
    }
  end

  defp empty_overview_bucket, do: %{count: 0, newest: nil}

  defp empty_jobs_hotspots do
    %{
      actionable_count: 0,
      workers: [],
      queues: [],
      pools: [],
      accounts: [],
      targets: []
    }
  end

  defp empty_jobs_hotspots_accumulator do
    empty_jobs_hotspots()
    |> Map.merge(%{
      workers: %{},
      queues: %{},
      pools: %{},
      accounts: %{},
      targets: %{}
    })
  end

  defp apply_overview_filters(queryable, filters) do
    queryable
    |> maybe_filter_explorer_worker(filters.worker)
    |> maybe_filter_explorer_queue(filters.queue)
    |> maybe_filter_explorer_target(filters.target_kind, filters.target_id)
  end

  defp collect_overview_job(job, overview, now) do
    job = job |> sanitize_explorer_error_summary() |> HealthPolicy.put_attention(now: now)
    overview = %{overview | total: overview.total + 1}

    case job.attention_state do
      attention_state when attention_state in @overview_action_buckets ->
        collect_overview_actionable_job(overview, attention_state, job)

      :healthy_context ->
        collect_completed_context_job(overview, job)

      _other_state ->
        overview
    end
  end

  defp collect_overview_actionable_job(overview, attention_state, job) do
    bucket = Map.fetch!(overview.buckets, attention_state)

    bucket = %{
      bucket
      | count: bucket.count + 1,
        newest: bucket.newest || job
    }

    %{
      overview
      | actionable_count: overview.actionable_count + 1,
        buckets: Map.put(overview.buckets, attention_state, bucket)
    }
  end

  defp collect_completed_context_job(overview, job) do
    bucket = overview.completed_context

    %{
      overview
      | completed_context_count: overview.completed_context_count + 1,
        completed_context: %{bucket | count: bucket.count + 1, newest: bucket.newest || job}
    }
  end

  defp finalize_jobs_overview(%{total: 0} = overview), do: overview

  defp finalize_jobs_overview(%{actionable_count: actionable_count} = overview)
       when actionable_count > 0 do
    %{overview | status: :attention_required, empty?: false, healthy?: false}
  end

  defp finalize_jobs_overview(overview) do
    %{overview | status: :healthy, empty?: false, healthy?: true}
  end

  defp collect_hotspot_job(job, hotspots, now) do
    job = HealthPolicy.put_attention(job, now: now)

    if job.attention_state in @overview_action_buckets do
      hotspots
      |> Map.update!(:actionable_count, &(&1 + 1))
      |> collect_hotspot(:workers, worker_hotspot_entry(job))
      |> collect_hotspot(:queues, queue_hotspot_entry(job))
      |> collect_hotspot(:pools, pool_hotspot_entry(job.target))
      |> collect_hotspot(:accounts, account_hotspot_entry(job.target))
      |> collect_hotspot(:targets, target_hotspot_entry(job.target))
    else
      hotspots
    end
  end

  defp collect_hotspot(hotspots, _collection, nil), do: hotspots

  defp collect_hotspot(hotspots, collection, {key, entry}) do
    updated_collection =
      hotspots
      |> Map.fetch!(collection)
      |> Map.update(
        key,
        Map.put(entry, :count, 1),
        &Map.update!(&1, :count, fn count -> count + 1 end)
      )

    Map.put(hotspots, collection, updated_collection)
  end

  defp finalize_jobs_hotspots(hotspots) do
    %{
      actionable_count: hotspots.actionable_count,
      workers: ranked_hotspots(hotspots.workers),
      queues: ranked_hotspots(hotspots.queues),
      pools: ranked_hotspots(hotspots.pools),
      accounts: ranked_hotspots(hotspots.accounts),
      targets: ranked_hotspots(hotspots.targets, @hotspot_target_limit)
    }
  end

  defp ranked_hotspots(entries, limit \\ @hotspot_limit) do
    entries
    |> Map.values()
    |> Enum.sort_by(&hotspot_sort_key/1)
    |> Enum.take(limit)
  end

  defp hotspot_sort_key(entry) do
    {-entry.count, Map.get(entry, :label, ""), Map.get(entry, :kind, :none),
     Map.get(entry, :id, "")}
  end

  defp worker_hotspot_entry(%{worker: worker}) when is_binary(worker) and worker != "" do
    {worker, %{worker: worker, label: worker_label(worker)}}
  end

  defp worker_hotspot_entry(_job), do: nil

  defp queue_hotspot_entry(job) do
    case Map.get(job, :queue) do
      queue when is_binary(queue) and queue != "" -> {queue, %{queue: queue, label: queue}}
      _missing_queue -> nil
    end
  end

  defp pool_hotspot_entry(%{pool_id: pool_id} = target)
       when is_binary(pool_id) and pool_id != "" do
    {pool_id, %{id: pool_id, label: present_string(target.pool_name) || "Pool unavailable"}}
  end

  defp pool_hotspot_entry(_target), do: nil

  defp account_hotspot_entry(target) do
    case account_target(target) do
      {account_id, label} -> {account_id, %{id: account_id, label: label}}
      nil -> nil
    end
  end

  defp target_hotspot_entry(%{assignment_id: assignment_id} = target)
       when is_binary(assignment_id) and assignment_id != "" do
    {
      {:assignment, assignment_id},
      %{
        kind: :assignment,
        id: assignment_id,
        label: present_string(target.assignment_label) || "Assignment unavailable"
      }
    }
  end

  defp target_hotspot_entry(target) do
    case account_target(target) do
      {account_id, label} ->
        {{:upstream_identity, account_id},
         %{kind: :upstream_identity, id: account_id, label: label}}

      nil ->
        non_account_target_hotspot_entry(target)
    end
  end

  defp non_account_target_hotspot_entry(%{pool_id: pool_id} = target)
       when is_binary(pool_id) and pool_id != "" do
    {{:pool, pool_id},
     %{kind: :pool, id: pool_id, label: present_string(target.pool_name) || "Pool unavailable"}}
  end

  defp non_account_target_hotspot_entry(%{api_key_id: api_key_id} = target)
       when is_binary(api_key_id) and api_key_id != "" do
    label =
      present_string(target.api_key_label) ||
        present_string(target.api_key_prefix) ||
        "API key unavailable"

    {{:api_key, api_key_id}, %{kind: :api_key, id: api_key_id, label: label}}
  end

  defp non_account_target_hotspot_entry(%{rollup_date: rollup_date})
       when is_binary(rollup_date) and rollup_date != "" do
    {{:rollup_date, rollup_date},
     %{kind: :rollup_date, id: rollup_date, label: "Rollup date #{rollup_date}"}}
  end

  defp non_account_target_hotspot_entry(_target) do
    {:system, %{kind: :system, id: nil, label: "System job"}}
  end

  defp account_target(%{assignment_identity_id: account_id} = target)
       when is_binary(account_id) and account_id != "" do
    {account_id, present_string(target.assignment_identity_label) || "Account unavailable"}
  end

  defp account_target(%{upstream_identity_id: account_id} = target)
       when is_binary(account_id) and account_id != "" do
    {account_id, present_string(target.direct_identity_label) || "Account unavailable"}
  end

  defp account_target(_target), do: nil

  defp worker_label(worker) do
    worker
    |> String.replace_prefix("CodexPooler.Jobs.", "")
    |> String.replace_suffix("Worker", "")
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp attention_filtered_explorer_page(queryable, attention, limit, offset, opts) do
    now = attention_now(opts)

    {:ok, {total, items}} =
      Repo.transaction(fn ->
        queryable
        |> job_explorer_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> Repo.stream()
        |> Enum.reduce({0, []}, fn job, {total, items} ->
          collect_attention_explorer_item({total, items}, job, attention, now, limit, offset)
        end)
      end)

    %{
      items: items |> Enum.reverse() |> sanitize_explorer_error_summaries(),
      total: total,
      limit: limit,
      offset: offset
    }
  end

  defp collect_attention_explorer_item({total, items}, job, attention, now, limit, offset) do
    job = HealthPolicy.put_attention(job, now: now)

    if Atom.to_string(job.attention_state) == attention do
      {total + 1, maybe_collect_explorer_item(items, job, total, limit, offset)}
    else
      {total, items}
    end
  end

  defp maybe_collect_explorer_item(items, job, total, limit, offset) do
    if total >= offset and length(items) < limit do
      [job | items]
    else
      items
    end
  end

  defp job_metadata_query(queryable) do
    from [
           job,
           pool,
           assignment,
           assignment_identity,
           direct_identity,
           api_key
         ] in job_target_metadata_query(queryable),
         select: %{
           id: job.id,
           worker: job.worker,
           queue: job.queue,
           state: job.state,
           errors: job.errors,
           attempt: job.attempt,
           max_attempts: job.max_attempts,
           inserted_at: job.inserted_at,
           scheduled_at: job.scheduled_at,
           attempted_at: job.attempted_at,
           completed_at: job.completed_at,
           discarded_at: job.discarded_at,
           cancelled_at: job.cancelled_at,
           target: %{
             pool_id: fragment("?->>?", job.args, "pool_id"),
             pool_name: pool.name,
             pool_slug: pool.slug,
             assignment_id: fragment("?->>?", job.args, "pool_upstream_assignment_id"),
             assignment_label: assignment.assignment_label,
             assignment_status: assignment.status,
             assignment_identity_id: type(assignment.upstream_identity_id, :string),
             upstream_identity_id: fragment("?->>?", job.args, "upstream_identity_id"),
             assignment_identity_label: assignment_identity.account_label,
             assignment_identity_status: assignment_identity.status,
             direct_identity_label: direct_identity.account_label,
             direct_identity_status: direct_identity.status,
             api_key_id: fragment("?->>?", job.args, "api_key_id"),
             api_key_label: api_key.display_name,
             api_key_prefix: api_key.key_prefix,
             rollup_date: fragment("?->>?", job.args, "rollup_date")
           }
         }
  end

  defp job_explorer_metadata_query(queryable) do
    from [
           job,
           pool,
           assignment,
           assignment_identity,
           direct_identity,
           api_key
         ] in job_target_metadata_query(queryable),
         select: %{
           id: job.id,
           worker: job.worker,
           queue: job.queue,
           state: job.state,
           errors: job.errors,
           attempt: job.attempt,
           max_attempts: job.max_attempts,
           inserted_at: job.inserted_at,
           scheduled_at: job.scheduled_at,
           attempted_at: job.attempted_at,
           completed_at: job.completed_at,
           discarded_at: job.discarded_at,
           cancelled_at: job.cancelled_at,
           target: %{
             pool_id: fragment("?->>?", job.args, "pool_id"),
             pool_name: pool.name,
             pool_slug: pool.slug,
             assignment_id: fragment("?->>?", job.args, "pool_upstream_assignment_id"),
             assignment_label: assignment.assignment_label,
             assignment_status: assignment.status,
             assignment_identity_id: type(assignment.upstream_identity_id, :string),
             upstream_identity_id: fragment("?->>?", job.args, "upstream_identity_id"),
             assignment_identity_label: assignment_identity.account_label,
             assignment_identity_status: assignment_identity.status,
             direct_identity_label: direct_identity.account_label,
             direct_identity_status: direct_identity.status,
             api_key_id: fragment("?->>?", job.args, "api_key_id"),
             api_key_label: api_key.display_name,
             api_key_prefix: api_key.key_prefix,
             rollup_date: fragment("?->>?", job.args, "rollup_date")
           }
         }
  end

  defp sanitize_explorer_error_summaries(jobs),
    do: Enum.map(jobs, &sanitize_explorer_error_summary/1)

  defp sanitize_explorer_error_summary(%{errors: [latest_error | _errors]} = job)
       when is_map(latest_error) do
    job
    |> Map.delete(:errors)
    |> Map.put(:failure_summary, failure_summary(latest_error))
  end

  defp sanitize_explorer_error_summary(job), do: Map.delete(job, :errors)

  defp failure_summary(error) do
    %{
      title: failure_title(error),
      message: error |> Map.get("error") |> safe_failure_message()
    }
  end

  defp failure_title(error) do
    [failure_attempt(error), failure_kind(error)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Failure detail"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp failure_attempt(%{"attempt" => attempt}) when is_integer(attempt), do: "Attempt #{attempt}"
  defp failure_attempt(%{"attempt" => attempt}) when is_binary(attempt), do: "Attempt #{attempt}"
  defp failure_attempt(_error), do: nil

  defp failure_kind(%{"kind" => kind}) when is_binary(kind) and kind != "", do: kind
  defp failure_kind(_error), do: nil

  defp safe_failure_message(message) when is_binary(message) do
    message
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> redact_failure_secrets()
    |> String.trim()
    |> truncate_failure_message()
    |> case do
      "" -> "No diagnostic message recorded."
      message -> message
    end
  end

  defp safe_failure_message(_message), do: "No diagnostic message recorded."

  defp redact_failure_secrets(message) do
    message
    |> String.replace(~r/(?i)bearer\s+[a-z0-9._~+\/=:-]+/, "Bearer [redacted]")
    |> String.replace(~r/(?i)\bsecret[-_a-z0-9]*\b/, "[redacted]")
    |> String.replace(
      ~r/(?i)\b(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token)\b\s*[:=]\s*[^,;\s]+/,
      "[redacted]"
    )
  end

  defp truncate_failure_message(message) when byte_size(message) > 240,
    do: message |> binary_part(0, 240) |> String.trim() |> Kernel.<>("…")

  defp truncate_failure_message(message), do: message

  defp job_target_metadata_query(queryable) do
    from job in queryable,
      left_join: pool in Pool,
      on: fragment("?->>?", job.args, "pool_id") == type(pool.id, :string),
      left_join: assignment in PoolUpstreamAssignment,
      on:
        fragment("?->>?", job.args, "pool_upstream_assignment_id") ==
          type(assignment.id, :string),
      left_join: assignment_identity in UpstreamIdentity,
      on: assignment.upstream_identity_id == assignment_identity.id,
      left_join: direct_identity in UpstreamIdentity,
      on:
        fragment("?->>?", job.args, "upstream_identity_id") == type(direct_identity.id, :string),
      left_join: api_key in APIKey,
      on: fragment("?->>?", job.args, "api_key_id") == type(api_key.id, :string)
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp pool_id(%{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp identity_id(%{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil
end
