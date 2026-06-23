defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.OAuthCallback
  alias CodexPooler.Upstreams.Schemas.OAuthFlow
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel
  alias CodexPoolerWeb.DateTimeDisplay

  @type cockpit :: UpstreamCockpitReadModel.t()

  @impl true
  def mount(%{"id" => identity_id}, _session, socket) do
    socket =
      socket
      |> assign(
        cockpit: nil,
        page_title: "Upstream cockpit",
        refresh_data_message: nil,
        auth_json_form: UpstreamAuthJsonImport.empty_form(),
        auth_json_upload_limit_label: UpstreamAuthJsonImport.upload_limit_label(),
        dialog_pool_options: [],
        importing_auth_json: false,
        oauth_relinking: false,
        oauth_relink_form: oauth_relink_form(),
        oauth_relink_flow: nil,
        oauth_relink_authorization_url: nil,
        oauth_relink_result: nil,
        oauth_relink_error: nil,
        oauth_relink_poll_timer: nil,
        renaming_account: nil,
        rename_account_form: nil,
        deleting_account: nil,
        delete_account_form: delete_account_form(nil),
        saved_reset_policy_form: saved_reset_policy_form(%{}),
        confirming_saved_reset_redemption: nil,
        subscribed_pool_ids: MapSet.new()
      )
      |> allow_upload(:auth_json,
        accept: ~w(.json),
        max_entries: 1,
        max_file_size: UpstreamAuthJsonImport.upload_limit_bytes(),
        chunk_size: 16_000,
        chunk_timeout: 5_000,
        auto_upload: true
      )

    case UpstreamCockpitReadModel.load_visible(socket.assigns.current_scope, identity_id) do
      {:ok, cockpit} ->
        {:ok, assign_cockpit(socket, cockpit)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Upstream account was not found")
         |> redirect(to: ~p"/admin/upstreams")}
    end
  end

  @impl true
  def handle_info({Events, %{topics: topics, payload: payload}}, socket) do
    if "upstreams" in topics and upstream_event_in_scope?(socket, payload) do
      {:noreply, load_cockpit(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:poll_oauth_relink_device, flow_id}, socket) do
    socket = assign(socket, :oauth_relink_poll_timer, nil)

    if oauth_relink_flow_id?(socket.assigns.oauth_relink_flow, flow_id) do
      poll_oauth_relink_device(socket, flow_id)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_data", _params, socket) do
    {:noreply,
     socket |> load_cockpit() |> assign(:refresh_data_message, "Cockpit data refreshed")}
  end

  @impl true
  def handle_event("open_rename_account", %{"id" => identity_id}, socket) do
    if action_available?(socket, :rename, identity_id) do
      {:noreply,
       assign(socket,
         renaming_account: %{id: identity_id, label: socket.assigns.cockpit.header.title},
         rename_account_form: rename_account_form(socket.assigns.cockpit.header.title),
         confirming_saved_reset_redemption: nil
       )}
    else
      {:noreply, put_unavailable_action_error(socket, :rename)}
    end
  end

  def handle_event("cancel_rename_account", _params, socket) do
    {:noreply, close_rename_account_dialog(socket)}
  end

  def handle_event("validate_rename_account", %{"rename" => rename_params}, socket) do
    {:noreply,
     assign(
       socket,
       :rename_account_form,
       rename_account_form(current_label(socket), rename_params, :validate)
     )}
  end

  def handle_event("rename_account", %{"rename" => rename_params}, socket) do
    identity_id = socket.assigns.cockpit.identity.id

    case Upstreams.rename_account_for_scope(
           socket.assigns.current_scope,
           identity_id,
           rename_params
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Upstream account renamed")
         |> close_rename_account_dialog()
         |> load_cockpit()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :rename_account_form, Phoenix.Component.to_form(changeset, as: :rename))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("pause_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      :pause,
      &Upstreams.pause_account_for_scope/3,
      "Upstream account paused"
    )
  end

  def handle_event("reactivate_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      :reactivate,
      &Upstreams.reactivate_account_for_scope/3,
      "Upstream account reactivated"
    )
  end

  def handle_event("refresh_account", %{"id" => identity_id}, socket) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      action_available?(socket, :refresh_token, identity_id) ->
        enqueue_token_refresh(socket, identity_id)

      true ->
        {:noreply, put_unavailable_action_error(socket, :refresh_token)}
    end
  end

  def handle_event("open_import_auth_json", params, socket) do
    identity_id = Map.get(params, "id", socket.assigns.cockpit.identity.id)

    if action_available?(socket, :replace_auth_json, identity_id) do
      pool_id =
        Map.get(params, "pool-id") || Map.get(params, "pool_id") ||
          default_pool_id(socket.assigns.cockpit)

      {:noreply,
       socket
       |> cancel_auth_json_upload_entries()
       |> assign(
         importing_auth_json: true,
         auth_json_form: auth_json_form_for_pool(socket, pool_id),
         confirming_saved_reset_redemption: nil
       )}
    else
      {:noreply, put_unavailable_action_error(socket, :replace_auth_json)}
    end
  end

  def handle_event("cancel_import_auth_json", _params, socket) do
    {:noreply, close_auth_json_dialog(socket)}
  end

  def handle_event("open_oauth_relink", %{"id" => identity_id}, socket) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      action_available?(socket, :oauth_relink, identity_id) ->
        {:noreply,
         socket
         |> close_auth_json_dialog()
         |> close_rename_account_dialog()
         |> close_delete_account_dialog()
         |> close_oauth_relink_dialog()
         |> close_saved_reset_redemption_confirmation()
         |> assign(oauth_relinking: true, oauth_relink_form: oauth_relink_form())}

      true ->
        {:noreply, put_unavailable_action_error(socket, :oauth_relink)}
    end
  end

  def handle_event("start_oauth_relink_browser", _params, socket) do
    case default_relink_pool(socket) do
      nil ->
        {:noreply,
         assign_oauth_relink_error(socket, OAuthCallback.safe_error(:unauthorized_pool))}

      pool ->
        case Upstreams.start_browser_oauth(socket.assigns.current_scope, pool,
               upstream_identity_id: socket.assigns.cockpit.identity.id,
               metadata: %{"source" => "admin_upstream_cockpit"}
             ) do
          {:ok, %{flow: %OAuthFlow{} = flow, authorization_url: authorization_url}} ->
            {:noreply,
             socket
             |> cancel_oauth_relink_poll_timer()
             |> assign(
               oauth_relink_flow: flow,
               oauth_relink_authorization_url: authorization_url,
               oauth_relink_result: %{message: "Browser authorization pending"},
               oauth_relink_error: nil,
               oauth_relink_form: oauth_relink_form()
             )
             |> refresh_oauth_flow_state()}

          {:error, reason} ->
            {:noreply, assign_oauth_relink_error(socket, reason)}
        end
    end
  end

  def handle_event("start_oauth_relink_device", _params, socket) do
    case default_relink_pool(socket) do
      nil ->
        {:noreply,
         assign_oauth_relink_error(socket, OAuthCallback.safe_error(:unauthorized_pool))}

      pool ->
        case Upstreams.start_device_oauth(socket.assigns.current_scope, pool,
               upstream_identity_id: socket.assigns.cockpit.identity.id,
               metadata: %{"source" => "admin_upstream_cockpit"}
             ) do
          {:ok, %{flow: %OAuthFlow{} = flow}} ->
            {:noreply,
             socket
             |> assign(
               oauth_relink_flow: flow,
               oauth_relink_authorization_url: nil,
               oauth_relink_result: %{message: "Device authorization pending"},
               oauth_relink_error: nil,
               oauth_relink_form: oauth_relink_form()
             )
             |> refresh_oauth_flow_state()
             |> schedule_oauth_relink_device_poll(flow)}

          {:error, reason} ->
            {:noreply, assign_oauth_relink_error(socket, reason)}
        end
    end
  end

  def handle_event("submit_oauth_relink_callback", %{"oauth_relink" => oauth_params}, socket) do
    callback_url = Map.get(oauth_params, "callback_url", "")

    case socket.assigns.oauth_relink_flow do
      %OAuthFlow{id: flow_id} ->
        case Upstreams.complete_browser_oauth(
               socket.assigns.current_scope,
               flow_id,
               callback_url
             ) do
          {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
            {:noreply, complete_oauth_relink(socket, flow)}

          {:ok, %{flow: %OAuthFlow{} = flow}} ->
            {:noreply,
             assign(socket,
               oauth_relink_flow: flow,
               oauth_relink_form: oauth_relink_form()
             )}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign_oauth_relink_error(reason)
             |> refresh_oauth_flow_state()}
        end

      nil ->
        {:noreply, assign_oauth_relink_error(socket, OAuthCallback.safe_error(:flow_not_pending))}
    end
  end

  def handle_event("cancel_oauth_relink", _params, socket) do
    socket = cancel_oauth_relink_poll_timer(socket)

    case socket.assigns.oauth_relink_flow do
      %OAuthFlow{id: flow_id, status: "pending"} ->
        case Upstreams.cancel_oauth_flow(socket.assigns.current_scope, flow_id) do
          {:ok, _flow} ->
            {:noreply, socket |> close_oauth_relink_dialog() |> refresh_oauth_flow_state()}

          {:error, reason} ->
            {:noreply, assign_oauth_relink_error(socket, reason)}
        end

      _flow ->
        {:noreply, close_oauth_relink_dialog(socket)}
    end
  end

  def handle_event("validate_auth_json_import", %{"auth_json" => auth_json_params}, socket) do
    if UpstreamAuthJsonImport.content_present?(auth_json_params) do
      {:noreply, socket}
    else
      {:noreply,
       assign(
         socket,
         :auth_json_form,
         auth_json_form_for_pool(socket, auth_json_params["pool_id"])
       )}
    end
  end

  def handle_event("cancel_auth_json_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :auth_json, ref)}
  end

  def handle_event("import_auth_json", %{"auth_json" => auth_json_params}, socket) do
    pool = selected_pool(socket.assigns.current_scope, auth_json_params["pool_id"])

    case import_auth_json_content(socket, auth_json_params) do
      {:ok, content, socket} ->
        do_import_auth_json(socket, pool, auth_json_params, content)

      {:error, message, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(
           auth_json_form:
             UpstreamAuthJsonImport.form_with_error(
               auth_json_params["pool_id"],
               :content,
               message
             ),
           importing_auth_json: true
         )}
    end
  end

  def handle_event("open_delete_account", %{"id" => identity_id}, socket) do
    if action_available?(socket, :delete, identity_id) do
      account = %{id: identity_id, label: socket.assigns.cockpit.header.title}

      {:noreply,
       assign(socket,
         deleting_account: account,
         delete_account_form: delete_account_form(account),
         confirming_saved_reset_redemption: nil
       )}
    else
      {:noreply, put_unavailable_action_error(socket, :delete)}
    end
  end

  def handle_event("cancel_delete_account", _params, socket) do
    {:noreply, close_delete_account_dialog(socket)}
  end

  def handle_event("confirm_delete_account", %{"upstream_delete" => delete_params}, socket) do
    case validate_delete_confirmation(socket.assigns.deleting_account, delete_params) do
      :ok ->
        identity_id = socket.assigns.cockpit.identity.id

        case Upstreams.soft_delete_account_for_scope(socket.assigns.current_scope, identity_id, %{
               reason: "admin_upstream_cockpit_live"
             }) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> put_flash(:info, "Upstream account deleted")
             |> close_delete_account_dialog()
             |> redirect(to: ~p"/admin/upstreams")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end

      {:error, form} ->
        {:noreply, assign(socket, :delete_account_form, form)}
    end
  end

  def handle_event("save_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    case Upstreams.update_saved_reset_policy_for_scope(
           socket.assigns.current_scope,
           socket.assigns.cockpit.identity.id,
           params
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved reset policy updated")
         |> load_cockpit()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "open_saved_reset_redemption_confirmation",
        %{"id" => identity_id} = params,
        socket
      ) do
    pool_id = Map.get(params, "pool-id") || Map.get(params, "pool_id")

    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      action_available?(socket, :redeem_saved_reset, identity_id) ->
        {:noreply,
         assign(socket, :confirming_saved_reset_redemption, %{
           identity_id: identity_id,
           pool_id: pool_id,
           label: socket.assigns.cockpit.header.title
         })}

      true ->
        {:noreply, put_unavailable_action_error(socket, :redeem_saved_reset)}
    end
  end

  def handle_event("cancel_saved_reset_redemption", _params, socket) do
    {:noreply, close_saved_reset_redemption_confirmation(socket)}
  end

  def handle_event("redeem_saved_reset", %{"id" => identity_id} = params, socket) do
    pool_id = Map.get(params, "pool-id") || Map.get(params, "pool_id")

    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      not saved_reset_redemption_confirmed?(socket, identity_id, pool_id) ->
        {:noreply, put_flash(socket, :error, "Confirm saved reset redemption before queueing it")}

      action_available?(socket, :redeem_saved_reset, identity_id) ->
        enqueue_saved_reset_redemption(socket, identity_id, pool_id)

      true ->
        {:noreply, put_unavailable_action_error(socket, :redeem_saved_reset)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :datetime_preferences,
        DateTimeDisplay.preferences_for_user(assigns.current_scope.user)
      )

    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:upstreams}
      alert_notification_center={@alert_notification_center}
    >
      <UpstreamCockpitComponents.cockpit_page
        cockpit={@cockpit}
        auth_json_form={@auth_json_form}
        auth_json_upload_limit_label={@auth_json_upload_limit_label}
        dialog_pool_options={@dialog_pool_options}
        importing_auth_json={@importing_auth_json}
        oauth_relinking={@oauth_relinking}
        oauth_relink_form={@oauth_relink_form}
        oauth_relink_flow={@oauth_relink_flow}
        oauth_relink_authorization_url={@oauth_relink_authorization_url}
        oauth_relink_result={@oauth_relink_result}
        oauth_relink_error={@oauth_relink_error}
        renaming_account={@renaming_account}
        rename_account_form={@rename_account_form}
        deleting_account={@deleting_account}
        delete_account_form={@delete_account_form}
        saved_reset_policy_form={@saved_reset_policy_form}
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        refresh_data_message={@refresh_data_message}
        uploads={@uploads}
        datetime_preferences={@datetime_preferences}
      />
    </AdminComponents.admin_shell>
    """
  end

  defp enqueue_token_refresh(socket, identity_id) do
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id,
           trigger_kind: "admin_upstream_cockpit_live"
         ) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: "Token refresh is already queued", else: "Token refresh queued"

        {:noreply, socket |> put_flash(:info, message) |> load_cockpit()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp poll_oauth_relink_device(socket, flow_id) do
    case Upstreams.poll_device_oauth(socket.assigns.current_scope, flow_id) do
      {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
        {:noreply, complete_oauth_relink(socket, flow)}

      {:ok, %{status: :pending, flow: %OAuthFlow{} = flow}} ->
        {:noreply,
         socket
         |> assign(
           oauth_relink_flow: flow,
           oauth_relink_authorization_url: nil,
           oauth_relink_result: %{message: "Device authorization pending"},
           oauth_relink_error: nil,
           oauth_relink_form: oauth_relink_form()
         )
         |> refresh_oauth_flow_state()
         |> schedule_oauth_relink_device_poll(flow)}

      {:ok, %{flow: %OAuthFlow{} = flow}} ->
        {:noreply,
         assign(socket, oauth_relink_flow: flow, oauth_relink_form: oauth_relink_form())}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_oauth_relink_error(reason)
         |> refresh_oauth_flow_state()}
    end
  end

  defp complete_oauth_relink(socket, %OAuthFlow{} = flow) do
    socket
    |> cancel_oauth_relink_poll_timer()
    |> assign(
      oauth_relink_flow: flow,
      oauth_relink_authorization_url: nil,
      oauth_relink_result: %{message: "OpenAI account relinked"},
      oauth_relink_error: nil,
      oauth_relink_form: oauth_relink_form()
    )
    |> load_cockpit()
  end

  defp default_relink_pool(socket) do
    selected_pool(socket.assigns.current_scope, default_pool_id(socket.assigns.cockpit))
  end

  defp schedule_oauth_relink_device_poll(
         socket,
         %OAuthFlow{flow_kind: "device", status: "pending", interval_seconds: interval_seconds} =
           flow
       ) do
    socket = cancel_oauth_relink_poll_timer(socket)
    delay_ms = max(positive_integer(interval_seconds, 5) * 1_000, 1_000)
    timer = Process.send_after(self(), {:poll_oauth_relink_device, flow.id}, delay_ms)
    assign(socket, :oauth_relink_poll_timer, timer)
  end

  defp schedule_oauth_relink_device_poll(socket, _flow), do: socket

  defp cancel_oauth_relink_poll_timer(socket) do
    if is_reference(socket.assigns[:oauth_relink_poll_timer]) do
      Process.cancel_timer(socket.assigns.oauth_relink_poll_timer, async: false, info: false)
    end

    assign(socket, :oauth_relink_poll_timer, nil)
  end

  defp assign_oauth_relink_error(socket, reason) do
    assign(socket,
      oauth_relink_error: %{message: error_message(reason)},
      oauth_relink_result: nil,
      oauth_relink_form: oauth_relink_form()
    )
  end

  defp oauth_relink_form(callback_url \\ "") do
    Phoenix.Component.to_form(%{"callback_url" => callback_url}, as: :oauth_relink)
  end

  defp oauth_relink_flow_id?(%OAuthFlow{id: id}, id), do: true
  defp oauth_relink_flow_id?(_flow, _id), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp lifecycle_action(socket, identity_id, action_key, operation, success_message) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      action_available?(socket, action_key, identity_id) ->
        case operation.(socket.assigns.current_scope, identity_id, %{
               reason: "admin_upstream_cockpit_live"
             }) do
          {:ok, _result} ->
            {:noreply, socket |> put_flash(:info, success_message) |> load_cockpit()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end

      true ->
        {:noreply, put_unavailable_action_error(socket, action_key)}
    end
  end

  defp load_cockpit(socket) do
    case UpstreamCockpitReadModel.load_visible(
           socket.assigns.current_scope,
           socket.assigns.cockpit.identity.id
         ) do
      {:ok, cockpit} ->
        assign_cockpit(socket, cockpit)

      :error ->
        socket
        |> put_flash(:error, "Upstream account was not found")
        |> redirect(to: ~p"/admin/upstreams")
    end
  end

  defp assign_cockpit(socket, cockpit) do
    socket
    |> maybe_subscribe_pool_events(cockpit)
    |> assign(
      cockpit: cockpit,
      dialog_pool_options: dialog_pool_options(socket.assigns.current_scope),
      saved_reset_policy_form: saved_reset_policy_form(cockpit.saved_reset_policy)
    )
  end

  defp refresh_oauth_flow_state(%{assigns: %{cockpit: nil}} = socket), do: socket

  defp refresh_oauth_flow_state(socket) do
    cockpit = socket.assigns.cockpit

    oauth_flows =
      UpstreamAccountsReadModel.oauth_flow_state(
        socket.assigns.current_scope,
        Enum.map(cockpit.assignments.items, &%{id: &1.pool_id}),
        DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user),
        upstream_identity_ids: [cockpit.identity.id]
      )

    assign(socket, :cockpit, %{cockpit | oauth_flows: oauth_flows})
  end

  defp maybe_subscribe_pool_events(socket, cockpit) do
    cockpit.assignments.items
    |> Enum.map(&%{id: &1.pool_id})
    |> PoolEventSubscriptions.pool_id_set()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
      socket
    end)
  end

  defp upstream_event_in_scope?(socket, payload) do
    payload_upstream_identity_id(payload) == socket.assigns.cockpit.identity.id
  end

  defp payload_upstream_identity_id(%{"upstream_identity_id" => identity_id})
       when is_binary(identity_id),
       do: identity_id

  defp payload_upstream_identity_id(%{upstream_identity_id: identity_id})
       when is_binary(identity_id),
       do: identity_id

  defp payload_upstream_identity_id(_payload), do: nil

  defp action_available?(socket, action_key, identity_id) do
    cockpit = socket.assigns.cockpit

    identity_id == cockpit.identity.id and
      cockpit.actions |> Map.fetch!(action_key) |> Map.fetch!(:available?)
  end

  defp saved_reset_redemption_confirmed?(socket, identity_id, pool_id) do
    case socket.assigns.confirming_saved_reset_redemption do
      %{identity_id: ^identity_id, pool_id: ^pool_id} -> true
      _confirmation -> false
    end
  end

  defp put_unavailable_action_error(socket, action_key) do
    action = Map.fetch!(socket.assigns.cockpit.actions, action_key)
    reason = action.reason || "action is unavailable"
    put_flash(socket, :error, "#{action_label(action_key)} is not available: #{reason}")
  end

  defp action_label(:replace_auth_json), do: "Replace auth.json"
  defp action_label(:oauth_relink), do: "OAuth relink"
  defp action_label(:refresh_token), do: "Refresh token"
  defp action_label(:redeem_saved_reset), do: "Redeem saved reset"

  defp action_label(action_key),
    do: action_key |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp current_label(socket), do: socket.assigns.cockpit.header.title

  defp rename_account_form(label, attrs \\ %{}, action \\ nil) do
    data = %{account_label: label}

    {%{}, %{account_label: :string}}
    |> Ecto.Changeset.cast(Map.merge(data, attrs), [:account_label])
    |> Ecto.Changeset.validate_required([:account_label])
    |> Map.put(:action, action)
    |> Phoenix.Component.to_form(as: :rename)
  end

  defp saved_reset_policy_form(policy) when is_map(policy) do
    Phoenix.Component.to_form(
      %{
        "auto_redeem_enabled" => Map.get(policy, :enabled?, false),
        "trigger_mode" => Map.get(policy, :trigger_mode, "blocked"),
        "quota_threshold_percent" => Map.get(policy, :quota_threshold_percent, 95),
        "min_blocked_minutes" => Map.get(policy, :min_blocked_minutes, 60),
        "keep_credits" => Map.get(policy, :keep_credits, 0)
      },
      as: :saved_reset_policy
    )
  end

  defp enqueue_saved_reset_redemption(socket, identity_id, pool_id) do
    case Upstreams.enqueue_saved_reset_redemption_for_scope(
           socket.assigns.current_scope,
           identity_id,
           pool_id,
           trigger_kind: "admin_upstream_cockpit_live"
         ) do
      {:ok, %{status: :already_queued}} ->
        {:noreply,
         socket
         |> close_saved_reset_redemption_confirmation()
         |> put_flash(:info, "Saved reset redemption is already queued")
         |> load_cockpit()}

      {:ok, _result} ->
        {:noreply,
         socket
         |> close_saved_reset_redemption_confirmation()
         |> put_flash(:info, "Saved reset redemption queued")
         |> load_cockpit()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp close_rename_account_dialog(socket) do
    assign(socket, renaming_account: nil, rename_account_form: nil)
  end

  defp close_delete_account_dialog(socket) do
    assign(socket, deleting_account: nil, delete_account_form: delete_account_form(nil))
  end

  defp close_saved_reset_redemption_confirmation(socket) do
    assign(socket, :confirming_saved_reset_redemption, nil)
  end

  defp close_oauth_relink_dialog(socket) do
    socket
    |> cancel_oauth_relink_poll_timer()
    |> assign(
      oauth_relinking: false,
      oauth_relink_form: oauth_relink_form(),
      oauth_relink_flow: nil,
      oauth_relink_authorization_url: nil,
      oauth_relink_result: nil,
      oauth_relink_error: nil
    )
  end

  defp delete_account_form(nil) do
    Phoenix.Component.to_form(%{"id" => "", "confirmation_label" => ""}, as: :upstream_delete)
  end

  defp delete_account_form(%{id: id}) do
    Phoenix.Component.to_form(%{"id" => id, "confirmation_label" => ""}, as: :upstream_delete)
  end

  defp validate_delete_confirmation(%{id: id, label: label}, %{
         "id" => id,
         "confirmation_label" => confirmation
       }) do
    if String.trim(to_string(confirmation)) == label do
      :ok
    else
      {:error, delete_account_error_form(id, "type the account label exactly")}
    end
  end

  defp validate_delete_confirmation(%{id: id}, _params),
    do: {:error, delete_account_error_form(id, "type the account label exactly")}

  defp validate_delete_confirmation(nil, _params),
    do: {:error, delete_account_error_form("", "account was not selected")}

  defp delete_account_error_form(id, message) do
    data = %{id: id || "", confirmation_label: ""}

    {%{}, %{id: :string, confirmation_label: :string}}
    |> Ecto.Changeset.cast(data, [:id, :confirmation_label])
    |> Ecto.Changeset.add_error(:confirmation_label, message)
    |> Map.put(:action, :validate)
    |> Phoenix.Component.to_form(as: :upstream_delete)
  end

  defp auth_json_form_for_pool(socket, pool_id) do
    pool_id =
      if selected_pool(socket.assigns.current_scope, pool_id),
        do: pool_id,
        else: default_pool_id(socket.assigns.cockpit)

    UpstreamAuthJsonImport.form_for_pool(pool_id)
  end

  defp selected_pool(scope, pool_id) when is_binary(pool_id) do
    scope
    |> Pools.list_visible_pools()
    |> Enum.find(&(&1.id == pool_id))
  end

  defp selected_pool(_scope, _pool_id), do: nil

  defp dialog_pool_options(scope) do
    scope
    |> Pools.list_visible_pools()
    |> Enum.map(&{&1.name, &1.id})
    |> case do
      [] -> [{"No active Pools available", ""}]
      options -> options
    end
  end

  defp default_pool_id(%{assignments: %{items: [%{pool_id: pool_id} | _items]}}), do: pool_id
  defp default_pool_id(_cockpit), do: nil

  defp import_auth_json_content(socket, auth_json_params) do
    {completed_upload_entries, in_progress_upload_entries} = uploaded_entries(socket, :auth_json)
    upload_errors = UpstreamAuthJsonImport.upload_error_messages(socket.assigns.uploads.auth_json)

    case UpstreamAuthJsonImport.content_source(
           auth_json_params,
           completed_upload_entries,
           in_progress_upload_entries,
           upload_errors
         ) do
      {:ok, {:paste, content}} ->
        {:ok, content, socket}

      {:ok, :upload} ->
        consume_auth_json_upload(socket)

      {:error, message, :cancel_uploads} ->
        {:error, message, cancel_auth_json_upload_entries(socket)}

      {:error, message, :keep_uploads} ->
        {:error, message, socket}
    end
  end

  defp consume_auth_json_upload(socket) do
    case consume_uploaded_entries(socket, :auth_json, fn %{path: path}, _entry ->
           UpstreamAuthJsonImport.read_upload(path)
         end) do
      [content] when is_binary(content) ->
        if byte_size(content) <= UpstreamAuthJsonImport.upload_limit_bytes() do
          {:ok, content, socket}
        else
          {:error, "File must be #{UpstreamAuthJsonImport.upload_limit_label()} or smaller",
           socket}
        end

      [] ->
        {:error, "Paste auth.json or upload one .json file", socket}

      _entries ->
        {:error, "Uploaded auth.json could not be read", socket}
    end
  end

  defp cancel_auth_json_upload_entries(socket) do
    Enum.reduce(socket.assigns.uploads.auth_json.entries, socket, fn entry, socket ->
      cancel_upload(socket, :auth_json, entry.ref)
    end)
  end

  defp close_auth_json_dialog(socket) do
    socket
    |> cancel_auth_json_upload_entries()
    |> assign(importing_auth_json: false, auth_json_form: UpstreamAuthJsonImport.empty_form())
  end

  defp do_import_auth_json(socket, pool, auth_json_params, content) do
    case Upstreams.import_codex_auth_json(socket.assigns.current_scope, pool, content) do
      {:ok, %{status: :created}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json imported")
         |> close_auth_json_dialog()
         |> load_cockpit()}

      {:ok, %{status: :existing}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json matched an existing account; tokens updated")
         |> close_auth_json_dialog()
         |> load_cockpit()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(
           importing_auth_json: true,
           auth_json_form: Phoenix.Component.to_form(changeset, as: :auth_json)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(
           importing_auth_json: true,
           auth_json_form: UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
         )}
    end
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Operation failed"
end
