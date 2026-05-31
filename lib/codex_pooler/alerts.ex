defmodule CodexPooler.Alerts do
  @moduledoc """
  Authorization-aware alert rule, channel, and incident APIs.
  """

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts.AuditLog, as: AlertAudit
  alias CodexPooler.Alerts.EmailDelivery
  alias CodexPooler.Alerts.Evaluator
  alias CodexPooler.Alerts.IncidentLifecycle
  alias CodexPooler.Alerts.WebhookDelivery

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type rule_result :: {:ok, AlertRule.t()} | {:error, Ecto.Changeset.t() | access_error()}
  @type channel_projection :: %{
          required(:id) => Ecto.UUID.t(),
          required(:channel_type) => String.t(),
          required(:display_name) => String.t(),
          required(:state) => String.t(),
          required(:email_to) => String.t() | nil,
          required(:endpoint_scheme) => String.t() | nil,
          required(:endpoint_host) => String.t() | nil,
          required(:endpoint_path_prefix) => String.t() | nil,
          required(:endpoint_fingerprint) => String.t() | nil,
          required(:webhook_signing_secret_key_version) => String.t() | nil,
          required(:created_by_user_id) => Ecto.UUID.t() | nil,
          required(:disabled_at) => DateTime.t() | nil,
          required(:metadata) => map(),
          required(:created_at) => DateTime.t(),
          required(:updated_at) => DateTime.t()
        }
  @type channel_result ::
          {:ok, channel_projection()} | {:error, Ecto.Changeset.t() | access_error()}
  @type pool_target :: %{
          required(:id) => Ecto.UUID.t(),
          required(:slug) => String.t(),
          required(:name) => String.t()
        }
  @type incident_projection :: %{
          required(:id) => Ecto.UUID.t(),
          required(:dedupe_key) => String.t(),
          required(:scope_type) => String.t(),
          required(:rule_kind) => String.t(),
          required(:severity) => String.t(),
          required(:state) => String.t(),
          required(:pool_id) => Ecto.UUID.t() | nil,
          required(:upstream_identity_id) => Ecto.UUID.t() | nil,
          required(:occurrence_count) => pos_integer(),
          required(:first_seen_at) => DateTime.t(),
          required(:last_seen_at) => DateTime.t(),
          required(:acknowledged_at) => DateTime.t() | nil,
          required(:resolved_at) => DateTime.t() | nil,
          required(:safe_evidence_snapshot) => map(),
          required(:suppression_metadata) => map(),
          required(:impacted_pools) => [pool_target()],
          required(:visible_impacted_pool_count) => non_neg_integer(),
          required(:hidden_impacted_pool_count) => non_neg_integer(),
          required(:total_impacted_pool_count) => non_neg_integer(),
          required(:created_at) => DateTime.t(),
          required(:updated_at) => DateTime.t()
        }
  @type incident_result ::
          {:ok, incident_projection()} | {:error, Ecto.Changeset.t() | access_error()}
  @type evaluation_rule_result :: {:ok, AlertRule.t()} | {:error, :alert_rule_not_found}

  @spec list_manageable_pools(term()) :: {:ok, [Pool.t()]} | {:error, access_error()}
  def list_manageable_pools(%Scope{} = scope), do: Pools.list_pools(scope)

  def list_manageable_pools(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_rules(term(), keyword()) :: {:ok, [AlertRule.t()]} | {:error, access_error()}
  def list_rules(scope, opts \\ [])

  def list_rules(%Scope{} = scope, opts) when is_list(opts) do
    with {:ok, pool_ids} <- authorized_pool_filter(scope, Keyword.get(opts, :pool_id)) do
      {:ok,
       Repo.all(
         from rule in AlertRule,
           where: rule.pool_id in ^pool_ids,
           order_by: [asc: rule.created_at, asc: rule.id]
       )}
    end
  end

  def list_rules(_scope, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec create_rule(term(), map()) :: rule_result()
  def create_rule(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, pool_id} <- pool_id_from_attrs(attrs),
         {:ok, _decision} <- authorize_pool_operation(scope, pool_id) do
      now = now()

      attrs
      |> rule_attrs(scope, pool_id, now)
      |> insert_rule_with_channels(
        scope,
        Map.get(attrs, :channel_ids) || Map.get(attrs, "channel_ids") || [],
        now
      )
      |> AlertAudit.audit_rule_create(scope)
    end
  end

  def create_rule(_scope, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec update_rule(term(), AlertRule.t() | Ecto.UUID.t(), map()) :: rule_result()
  def update_rule(%Scope{} = scope, %AlertRule{} = rule, attrs) when is_map(attrs) do
    target_pool_id = Map.get(attrs, :pool_id) || Map.get(attrs, "pool_id") || rule.pool_id

    with {:ok, _existing_decision} <- authorize_pool_operation(scope, rule.pool_id),
         {:ok, _target_decision} <- authorize_pool_operation(scope, target_pool_id) do
      rule
      |> update_rule_with_channels(scope, rule_update_attrs(attrs, target_pool_id, now()))
      |> AlertAudit.audit_rule_update(scope, rule, attrs)
    end
  end

  def update_rule(%Scope{} = scope, rule_id, attrs) when is_binary(rule_id) and is_map(attrs) do
    case Repo.get(AlertRule, rule_id) do
      %AlertRule{} = rule -> update_rule(scope, rule, attrs)
      nil -> {:error, access_error(:rule_not_found, "alert rule was not found")}
    end
  end

  def update_rule(_scope, _rule, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp update_rule_with_channels(rule, scope, attrs) do
    Repo.transaction(fn -> update_rule_in_transaction(rule, scope, attrs) end)
  end

  defp update_rule_in_transaction(rule, scope, attrs) do
    with {:ok, updated_rule} <- rule |> AlertRule.changeset(attrs) |> Repo.update(),
         {:ok, _channels} <- maybe_sync_rule_channels(scope, updated_rule, attrs, now()) do
      updated_rule
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec delete_rule(term(), AlertRule.t() | Ecto.UUID.t()) :: rule_result()
  def delete_rule(%Scope{} = scope, %AlertRule{} = rule) do
    with {:ok, _decision} <- authorize_pool_operation(scope, rule.pool_id) do
      delete_rule_transaction(rule)
      |> AlertAudit.audit_rule_delete(scope)
    end
  end

  def delete_rule(%Scope{} = scope, rule_id) when is_binary(rule_id) do
    case Repo.get(AlertRule, rule_id) do
      %AlertRule{} = rule -> delete_rule(scope, rule)
      nil -> {:error, access_error(:rule_not_found, "alert rule was not found")}
    end
  end

  def delete_rule(_scope, _rule),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp delete_rule_transaction(rule) do
    Repo.transaction(fn -> delete_rule_in_transaction(rule) end)
  end

  defp delete_rule_in_transaction(rule) do
    case Repo.delete(rule) do
      {:ok, deleted_rule} -> deleted_rule
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec list_channels(term(), keyword()) ::
          {:ok, [channel_projection()]} | {:error, access_error()}
  def list_channels(scope, opts \\ [])

  def list_channels(%Scope{} = scope, opts) when is_list(opts) do
    {:ok,
     scope
     |> channel_scope_query()
     |> maybe_filter_channel_state(Keyword.get(opts, :state))
     |> order_by([channel], asc: channel.created_at, asc: channel.id)
     |> Repo.all()
     |> Enum.map(&channel_projection/1)}
  end

  def list_channels(_scope, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec create_channel(term(), map()) :: channel_result()
  def create_channel(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, _user_id} <- scope_user_id(scope) do
      now = now()

      %AlertChannel{}
      |> AlertChannel.changeset(channel_attrs(attrs, scope, now))
      |> Repo.insert()
      |> AlertAudit.audit_channel_create(scope)
      |> project_channel_result()
    end
  end

  def create_channel(_scope, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec update_channel(term(), AlertChannel.t() | Ecto.UUID.t(), map()) :: channel_result()
  def update_channel(%Scope{} = scope, %AlertChannel{} = channel, attrs) when is_map(attrs) do
    with {:ok, channel} <- authorize_channel_access(scope, channel) do
      channel
      |> AlertChannel.changeset(channel_update_attrs(attrs, now()))
      |> Repo.update()
      |> AlertAudit.audit_channel_update(scope, channel, attrs)
      |> project_channel_result()
    end
  end

  def update_channel(%Scope{} = scope, channel_id, attrs)
      when is_binary(channel_id) and is_map(attrs) do
    case Repo.get(AlertChannel, channel_id) do
      %AlertChannel{} = channel -> update_channel(scope, channel, attrs)
      nil -> {:error, access_error(:channel_not_found, "alert channel was not found")}
    end
  end

  def update_channel(_scope, _channel, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec delete_channel(term(), AlertChannel.t() | Ecto.UUID.t()) :: channel_result()
  def delete_channel(%Scope{} = scope, %AlertChannel{} = channel) do
    with {:ok, channel} <- authorize_channel_access(scope, channel) do
      channel
      |> Repo.delete()
      |> AlertAudit.audit_channel_delete(scope)
      |> project_channel_result()
    end
  end

  def delete_channel(%Scope{} = scope, channel_id) when is_binary(channel_id) do
    case Repo.get(AlertChannel, channel_id) do
      %AlertChannel{} = channel -> delete_channel(scope, channel)
      nil -> {:error, access_error(:channel_not_found, "alert channel was not found")}
    end
  end

  def delete_channel(_scope, _channel),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_incidents(term(), keyword()) ::
          {:ok, [incident_projection()]} | {:error, access_error()}
  def list_incidents(scope, opts \\ [])

  def list_incidents(%Scope{} = scope, opts) when is_list(opts) do
    with {:ok, pool_ids} <- authorized_pool_filter(scope, Keyword.get(opts, :pool_id)) do
      incidents =
        incident_query(pool_ids, opts)
        |> Repo.all()
        |> incident_projections(pool_ids)

      {:ok, incidents}
    end
  end

  def list_incidents(_scope, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec acknowledge_incident(term(), AlertIncident.t() | Ecto.UUID.t()) :: incident_result()
  def acknowledge_incident(scope, incident_or_id),
    do: transition_incident(scope, incident_or_id, :acknowledge)

  @spec resolve_incident(term(), AlertIncident.t() | Ecto.UUID.t()) :: incident_result()
  def resolve_incident(scope, incident_or_id),
    do: transition_incident(scope, incident_or_id, :resolve)

  @spec record_incident_match(IncidentLifecycle.match_attrs() | map()) ::
          IncidentLifecycle.record_result()
  defdelegate record_incident_match(attrs), to: IncidentLifecycle

  @spec safe_projected_metadata_for_admin(map()) :: map()
  def safe_projected_metadata_for_admin(metadata), do: safe_projected_metadata(metadata)

  @spec clear_incident_condition(IncidentLifecycle.clear_attrs() | map() | String.t()) ::
          IncidentLifecycle.clear_result()
  defdelegate clear_incident_condition(attrs), to: IncidentLifecycle

  @spec list_active_rules_for_evaluation(keyword()) :: [AlertRule.t()]
  def list_active_rules_for_evaluation(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 500) |> normalize_evaluation_limit()

    Repo.all(
      from rule in AlertRule,
        where: rule.state == "active",
        order_by: [asc: rule.created_at, asc: rule.id],
        limit: ^limit
    )
  end

  @spec fetch_rule_for_evaluation(Ecto.UUID.t()) :: evaluation_rule_result()
  def fetch_rule_for_evaluation(rule_id) when is_binary(rule_id) do
    case Repo.get(AlertRule, rule_id) do
      %AlertRule{} = rule -> {:ok, rule}
      nil -> {:error, :alert_rule_not_found}
    end
  end

  def fetch_rule_for_evaluation(_rule_id), do: {:error, :alert_rule_not_found}

  @spec evaluate_rule(AlertRule.t(), Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  def evaluate_rule(rule, opts \\ []), do: Evaluator.evaluate_rule(rule, opts)

  @spec evaluate_active_rules(Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  def evaluate_active_rules(opts \\ []), do: Evaluator.evaluate_active_rules(opts)

  @spec deliver_incident_to_channel(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, AlertDeliveryAttempt.t()}
          | {:error, EmailDelivery.delivery_error() | WebhookDelivery.delivery_error()}
  def deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts \\ []) do
    case Repo.get(AlertChannel, channel_id) do
      %AlertChannel{channel_type: "webhook"} ->
        WebhookDelivery.deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts)

      _channel ->
        EmailDelivery.deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts)
    end
  end

  @spec access_error(atom(), String.t()) :: access_error()
  def access_error(code, message), do: %{code: code, message: message}

  defp normalize_evaluation_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, 1_000)
  end

  defp normalize_evaluation_limit(_limit), do: 500

  defp authorized_pool_filter(%Scope{} = scope, nil) do
    case list_manageable_pools(scope) do
      {:ok, pools} -> {:ok, Enum.map(pools, & &1.id)}
      {:error, _reason} = error -> error
    end
  end

  defp authorized_pool_filter(%Scope{} = scope, pool_id) when is_binary(pool_id) do
    with {:ok, _decision} <- authorize_pool_operation(scope, pool_id), do: {:ok, [pool_id]}
  end

  defp authorized_pool_filter(_scope, _pool_id),
    do: {:error, access_error(:invalid_request, "pool id must be a string")}

  defp authorize_pool_operation(scope, pool_id) when is_binary(pool_id) do
    Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool_id)
  end

  defp authorize_pool_operation(_scope, _pool_id),
    do: {:error, access_error(:invalid_request, "pool id must be a string")}

  defp scope_user_id(%Scope{user: %{id: user_id}}) when is_binary(user_id), do: {:ok, user_id}

  defp scope_user_id(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp channel_scope_query(%Scope{} = scope) do
    query = from(channel in AlertChannel)

    if Pools.owner?(scope) do
      query
    else
      {:ok, user_id} = scope_user_id(scope)
      from channel in query, where: channel.created_by_user_id == ^user_id
    end
  end

  defp authorize_channel_access(%Scope{} = scope, %AlertChannel{} = channel) do
    if Pools.owner?(scope) do
      {:ok, channel}
    else
      case scope_user_id(scope) do
        {:ok, user_id} when channel.created_by_user_id == user_id -> {:ok, channel}
        {:ok, _user_id} -> {:error, channel_not_found_error()}
        {:error, _reason} = error -> error
      end
    end
  end

  defp channel_not_found_error,
    do: access_error(:channel_not_found, "alert channel was not found")

  defp pool_id_from_attrs(attrs) do
    case Map.get(attrs, :pool_id) || Map.get(attrs, "pool_id") do
      pool_id when is_binary(pool_id) -> {:ok, pool_id}
      _other -> {:error, access_error(:invalid_request, "pool id must be a string")}
    end
  end

  defp rule_attrs(attrs, scope, pool_id, timestamp) do
    attrs
    |> normalize_attrs(rule_attribute_keys())
    |> Map.merge(%{
      pool_id: pool_id,
      created_by_user_id: scope.user.id,
      disabled_at:
        disabled_at_for_state(Map.get(attrs, :state) || Map.get(attrs, "state"), timestamp),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{},
      created_at: timestamp,
      updated_at: timestamp
    })
  end

  defp rule_update_attrs(attrs, target_pool_id, timestamp) do
    attrs
    |> normalize_attrs(rule_update_attribute_keys())
    |> Map.put(:pool_id, target_pool_id)
    |> maybe_put_disabled_at(attrs, timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp insert_rule_with_channels(attrs, scope, channel_ids, timestamp) do
    Repo.transaction(fn ->
      with {:ok, rule} <- %AlertRule{} |> AlertRule.changeset(attrs) |> Repo.insert(),
           {:ok, _channels} <- sync_rule_channels(scope, rule, channel_ids, timestamp) do
        rule
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp maybe_sync_rule_channels(scope, rule, attrs, timestamp) do
    case Map.fetch(attrs, :channel_ids) do
      {:ok, channel_ids} -> sync_rule_channels(scope, rule, channel_ids, timestamp)
      :error -> {:ok, []}
    end
  end

  defp sync_rule_channels(%Scope{} = scope, %AlertRule{} = rule, channel_ids, timestamp)
       when is_list(channel_ids) do
    channel_ids = Enum.filter(channel_ids, &is_binary/1) |> Enum.uniq()

    with {:ok, channel_ids} <- authorize_rule_channel_ids(scope, channel_ids) do
      Repo.delete_all(from link in AlertRuleChannel, where: link.alert_rule_id == ^rule.id)

      links =
        Enum.map(channel_ids, fn channel_id ->
          %{alert_rule_id: rule.id, alert_channel_id: channel_id, created_at: timestamp}
        end)

      if links == [] do
        {:ok, []}
      else
        {count, _rows} = Repo.insert_all(AlertRuleChannel, links)
        {:ok, count}
      end
    end
  end

  defp sync_rule_channels(_scope, _rule, _channel_ids, _timestamp),
    do: {:error, access_error(:invalid_request, "channel ids must be a list")}

  defp authorize_rule_channel_ids(%Scope{} = scope, channel_ids) do
    authorized_count =
      Repo.aggregate(
        from(channel in channel_scope_query(scope), where: channel.id in ^channel_ids),
        :count,
        :id
      )

    if authorized_count == length(channel_ids) do
      {:ok, channel_ids}
    else
      {:error, channel_not_found_error()}
    end
  end

  defp rule_attribute_keys do
    [
      :pool_id,
      :scope_type,
      :rule_kind,
      :display_name,
      :severity,
      :cooldown_minutes,
      :state,
      :model,
      :min_usable_assignments,
      :target_state,
      :window_selector,
      :threshold_used_percent,
      :metadata
    ]
  end

  defp rule_update_attribute_keys do
    rule_attribute_keys() ++ [:channel_ids]
  end

  defp channel_attrs(attrs, scope, timestamp) do
    attrs
    |> normalize_attrs(channel_attribute_keys())
    |> Map.merge(%{
      created_by_user_id: scope.user.id,
      disabled_at:
        disabled_at_for_state(Map.get(attrs, :state) || Map.get(attrs, "state"), timestamp),
      metadata: safe_channel_metadata(attrs),
      webhook_signing_secret_aad:
        Map.get(attrs, :webhook_signing_secret_aad) ||
          Map.get(attrs, "webhook_signing_secret_aad") || %{},
      created_at: timestamp,
      updated_at: timestamp
    })
  end

  defp channel_update_attrs(attrs, timestamp) do
    attrs
    |> normalize_attrs(channel_attribute_keys())
    |> maybe_put_channel_metadata(attrs)
    |> maybe_put_disabled_at(attrs, timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp channel_attribute_keys do
    [
      :channel_type,
      :display_name,
      :state,
      :email_to,
      :endpoint_url,
      :delivery_endpoint_url,
      :endpoint_scheme,
      :endpoint_host,
      :endpoint_path_prefix,
      :endpoint_fingerprint,
      :endpoint_url_ciphertext,
      :endpoint_url_nonce,
      :endpoint_url_aad,
      :endpoint_url_key_version,
      :webhook_signing_secret,
      :webhook_signing_secret_action,
      :webhook_signing_secret_ciphertext,
      :webhook_signing_secret_nonce,
      :webhook_signing_secret_aad,
      :webhook_signing_secret_key_version,
      :metadata
    ]
  end

  defp normalize_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> maybe_put_string_key(acc, attrs, key)
      end
    end)
  end

  defp maybe_put_string_key(acc, attrs, key) do
    string_key = Atom.to_string(key)

    case Map.fetch(attrs, string_key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp maybe_put_disabled_at(attrs, raw_attrs, timestamp) do
    case Map.get(raw_attrs, :state) || Map.get(raw_attrs, "state") do
      "disabled" -> Map.put(attrs, :disabled_at, timestamp)
      "active" -> Map.put(attrs, :disabled_at, nil)
      _state -> attrs
    end
  end

  defp disabled_at_for_state("disabled", timestamp), do: timestamp
  defp disabled_at_for_state(_state, _timestamp), do: nil

  defp maybe_put_channel_metadata(attrs, raw_attrs) do
    if Map.has_key?(raw_attrs, :metadata) or Map.has_key?(raw_attrs, "metadata") do
      Map.put(attrs, :metadata, safe_channel_metadata(raw_attrs))
    else
      attrs
    end
  end

  defp safe_channel_metadata(attrs) do
    case Map.get(attrs, :metadata) || Map.get(attrs, "metadata") do
      %{} = metadata -> Accounting.sanitize_metadata(metadata)
      nil -> %{}
      other -> other
    end
  end

  defp project_channel_result({:ok, %AlertChannel{} = channel}),
    do: {:ok, channel_projection(channel)}

  defp project_channel_result({:error, _reason} = error), do: error

  defp channel_projection(%AlertChannel{} = channel) do
    %{
      id: channel.id,
      channel_type: channel.channel_type,
      display_name: channel.display_name,
      state: channel.state,
      email_to: channel.email_to,
      endpoint_scheme: channel.endpoint_scheme,
      endpoint_host: channel.endpoint_host,
      endpoint_path_prefix: channel.endpoint_path_prefix,
      endpoint_fingerprint: channel.endpoint_fingerprint,
      webhook_signing_secret_key_version: channel.webhook_signing_secret_key_version,
      created_by_user_id: channel.created_by_user_id,
      disabled_at: channel.disabled_at,
      metadata: safe_projected_metadata(channel.metadata),
      created_at: channel.created_at,
      updated_at: channel.updated_at
    }
  end

  defp safe_projected_metadata(%{} = metadata), do: Accounting.sanitize_metadata(metadata)
  defp safe_projected_metadata(_metadata), do: %{}

  defp maybe_filter_channel_state(query, nil), do: query

  defp maybe_filter_channel_state(query, state),
    do: from(channel in query, where: channel.state == ^state)

  defp incident_query(pool_ids, opts) do
    state = Keyword.get(opts, :state)

    from(incident in AlertIncident, as: :incident)
    |> maybe_filter_incident_state(state)
    |> where(
      [incident],
      incident.pool_id in ^pool_ids or
        exists(
          from target in AlertIncidentTarget,
            where: target.incident_id == parent_as(:incident).id and target.pool_id in ^pool_ids,
            select: 1
        )
    )
    |> order_by([incident], desc: incident.last_seen_at, desc: incident.id)
  end

  defp maybe_filter_incident_state(query, nil), do: query

  defp maybe_filter_incident_state(query, state),
    do: from(incident in query, where: incident.state == ^state)

  defp transition_incident(%Scope{} = scope, incident_or_id, action) do
    with %AlertIncident{} = incident <- normalize_incident(incident_or_id),
         {:ok, pool_ids} <- authorized_pool_filter(scope, nil),
         true <- incident_visible?(incident, pool_ids) do
      update_incident_transition(scope, incident, pool_ids, action)
    else
      nil -> {:error, access_error(:incident_not_found, "alert incident was not found")}
      false -> {:error, access_error(:incident_not_found, "alert incident was not found")}
      {:error, _reason} = error -> error
    end
  end

  defp transition_incident(_scope, _incident_or_id, _action),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp update_incident_transition(scope, incident, pool_ids, action) do
    attrs = incident_transition_attrs(action, now())

    Repo.transaction(fn ->
      update_incident_transition_in_transaction(incident, attrs, pool_ids)
    end)
    |> AlertAudit.audit_incident_transition(scope, incident, action)
  end

  defp update_incident_transition_in_transaction(incident, attrs, pool_ids) do
    case incident |> AlertIncident.changeset(attrs) |> Repo.update() do
      {:ok, updated_incident} -> incident_projection(updated_incident, pool_ids)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp normalize_incident(%AlertIncident{} = incident), do: incident
  defp normalize_incident(id) when is_binary(id), do: Repo.get(AlertIncident, id)
  defp normalize_incident(_id), do: nil

  defp incident_transition_attrs(:acknowledge, timestamp),
    do: %{state: "acknowledged", acknowledged_at: timestamp, updated_at: timestamp}

  defp incident_transition_attrs(:resolve, timestamp),
    do: %{state: "resolved", resolved_at: timestamp, updated_at: timestamp}

  defp incident_visible?(%AlertIncident{pool_id: pool_id}, pool_ids) when is_binary(pool_id),
    do: pool_id in pool_ids

  defp incident_visible?(%AlertIncident{id: incident_id}, pool_ids) do
    Repo.exists?(
      from target in AlertIncidentTarget,
        where: target.incident_id == ^incident_id and target.pool_id in ^pool_ids
    )
  end

  defp incident_projections(incidents, pool_ids),
    do: Enum.map(incidents, &incident_projection(&1, pool_ids))

  defp incident_projection(%AlertIncident{} = incident, pool_ids) do
    pool_targets = incident_pool_targets(incident.id)
    visible_targets = Enum.filter(pool_targets, &(&1.pool_id in pool_ids))
    total_count = length(pool_targets)
    visible_count = length(visible_targets)

    %{
      id: incident.id,
      dedupe_key: incident.dedupe_key,
      scope_type: incident.scope_type,
      rule_kind: incident.rule_kind,
      severity: incident.severity,
      state: incident.state,
      pool_id: incident.pool_id,
      upstream_identity_id: incident.upstream_identity_id,
      occurrence_count: incident.occurrence_count,
      first_seen_at: incident.first_seen_at,
      last_seen_at: incident.last_seen_at,
      acknowledged_at: incident.acknowledged_at,
      resolved_at: incident.resolved_at,
      safe_evidence_snapshot: incident.safe_evidence_snapshot || %{},
      suppression_metadata: incident.suppression_metadata || %{},
      impacted_pools: Enum.map(visible_targets, &pool_target_projection/1),
      visible_impacted_pool_count: visible_count,
      hidden_impacted_pool_count: max(total_count - visible_count, 0),
      total_impacted_pool_count: total_count,
      created_at: incident.created_at,
      updated_at: incident.updated_at
    }
  end

  defp incident_pool_targets(incident_id) do
    Repo.all(
      from target in AlertIncidentTarget,
        join: pool in Pool,
        on: pool.id == target.pool_id,
        where: target.incident_id == ^incident_id,
        order_by: [asc: pool.created_at, asc: pool.id],
        select: %{pool_id: pool.id, pool_slug: pool.slug, pool_name: pool.name}
    )
  end

  defp pool_target_projection(target),
    do: %{id: target.pool_id, slug: target.pool_slug, name: target.pool_name}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
