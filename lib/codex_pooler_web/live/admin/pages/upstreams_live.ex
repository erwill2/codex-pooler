defmodule CodexPoolerWeb.Admin.UpstreamsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.OAuthCallback
  alias CodexPooler.Upstreams.Schemas.{OAuthFlow, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamFilterForm
  alias CodexPoolerWeb.Admin.UpstreamPageComponents
  alias CodexPoolerWeb.DateTimeDisplay

  @upstreams_reload_debounce_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Upstreams",
        pools: [],
        pool_options: [],
        dialog_pool_options: [],
        pool_filter_options: PoolFilterComponents.all_pool_filter_options(),
        filter_form: UpstreamFilterForm.filter_form(),
        filter_values: UpstreamFilterForm.filter_values(%{}, []),
        status_options: UpstreamFilterForm.status_options(),
        upstream_accounts: [],
        auth_json_form: UpstreamAuthJsonImport.empty_form(),
        auth_json_upload_limit_label: UpstreamAuthJsonImport.upload_limit_label(),
        importing_auth_json: false,
        oauth_linking: false,
        oauth_link_mode: :link,
        oauth_link_target_account: nil,
        oauth_link_form: oauth_link_form(),
        oauth_link_pool_id: "",
        oauth_link_flow: nil,
        oauth_link_authorization_url: nil,
        oauth_link_result: nil,
        oauth_link_error: nil,
        oauth_link_poll_timer: nil,
        renaming_account: nil,
        rename_account_form: nil,
        editing_saved_reset_policy: nil,
        saved_reset_policy_form: saved_reset_policy_form(%{}),
        confirming_saved_reset_redemption: nil,
        subscribed_pool_ids: MapSet.new(),
        upstreams_reload_timer: nil
      )
      |> allow_upload(:auth_json,
        accept: ~w(.json),
        max_entries: 1,
        max_file_size: UpstreamAuthJsonImport.upload_limit_bytes(),
        chunk_size: 16_000,
        chunk_timeout: 5_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> close_auth_json_dialog()
     |> close_rename_account_dialog()
     |> close_oauth_link_dialog()
     |> close_saved_reset_policy_dialog()
     |> load_upstreams(params)}
  end

  @impl true
  def handle_info({Events, %{topics: topics}}, socket) do
    if "upstreams" in topics do
      {:noreply, schedule_upstreams_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:reload_upstreams_from_events, socket) do
    {:noreply,
     socket
     |> assign(:upstreams_reload_timer, nil)
     |> reload_upstreams()}
  end

  @impl true
  def handle_info({:poll_oauth_device, flow_id}, socket) do
    socket = assign(socket, :oauth_link_poll_timer, nil)

    if oauth_flow_id?(socket.assigns.oauth_link_flow, flow_id) do
      poll_oauth_device(socket, flow_id)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(filter_params)}"
     )}
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket) do
    params = Map.put(socket.assigns.filter_values, "pool_id", pool_id)

    {:noreply,
     push_patch(socket, to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(params)}")}
  end

  def handle_event("clear_upstream_query_filter", _params, socket) do
    params = Map.put(socket.assigns.filter_values, "query", "")

    {:noreply,
     push_patch(socket, to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(params)}")}
  end

  def handle_event("select_status_filter", %{"status" => status}, socket) do
    params = Map.put(socket.assigns.filter_values, "status", status)

    {:noreply,
     push_patch(socket, to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(params)}")}
  end

  @impl true
  def handle_event("import_auth_json", %{"auth_json" => auth_json_params}, socket) do
    pool = selected_pool(socket.assigns.pools, auth_json_params["pool_id"])

    case import_auth_json_content(socket, auth_json_params) do
      {:ok, content, socket} ->
        do_import_auth_json(socket, pool, auth_json_params, content)

      {:error, message, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(
           :auth_json_form,
           UpstreamAuthJsonImport.form_with_error(auth_json_params["pool_id"], :content, message)
         )
         |> assign(:importing_auth_json, true)}
    end
  end

  def handle_event("open_import_auth_json", params, socket) do
    {:noreply,
     socket
     |> cancel_auth_json_upload_entries()
     |> close_saved_reset_policy_dialog()
     |> assign(
       importing_auth_json: true,
       auth_json_form: auth_json_form_for_open(socket.assigns.pools, params)
     )}
  end

  def handle_event("cancel_import_auth_json", _params, socket) do
    {:noreply, close_auth_json_dialog(socket)}
  end

  def handle_event("open_oauth_link", params, socket) do
    pool_id = oauth_link_pool_id_for_open(socket.assigns.pools, params)

    {:noreply,
     socket
     |> close_auth_json_dialog()
     |> close_rename_account_dialog()
     |> close_oauth_link_dialog()
     |> close_saved_reset_policy_dialog()
     |> assign(
       oauth_linking: true,
       oauth_link_mode: :link,
       oauth_link_target_account: nil,
       oauth_link_form: oauth_link_form(pool_id),
       oauth_link_pool_id: pool_id
     )}
  end

  def handle_event("open_oauth_relink", %{"id" => identity_id}, socket) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      account ->
        case oauth_relink_pool_id(account) do
          {:ok, pool_id} ->
            {:noreply,
             socket
             |> close_auth_json_dialog()
             |> close_rename_account_dialog()
             |> close_oauth_link_dialog()
             |> close_saved_reset_policy_dialog()
             |> assign(
               oauth_linking: true,
               oauth_link_mode: :relink,
               oauth_link_target_account: account,
               oauth_link_form: oauth_link_form(pool_id),
               oauth_link_pool_id: pool_id
             )}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  def handle_event("validate_oauth_link_pool", %{"oauth_link" => oauth_params}, socket) do
    if oauth_relink_mode?(socket) do
      {:noreply, socket}
    else
      pool_id = Map.get(oauth_params, "pool_id", "")

      {:noreply,
       assign(socket,
         oauth_link_pool_id: pool_id,
         oauth_link_form: oauth_link_form(pool_id),
         oauth_link_error: nil
       )}
    end
  end

  def handle_event("start_oauth_browser", params, socket) do
    case selected_oauth_pool(socket, params) do
      nil ->
        {:noreply, assign_oauth_error(socket, OAuthCallback.safe_error(:unauthorized_pool))}

      pool ->
        case Upstreams.start_browser_oauth(
               socket.assigns.current_scope,
               pool,
               oauth_start_opts(socket)
             ) do
          {:ok, %{flow: %OAuthFlow{} = flow, authorization_url: authorization_url}} ->
            {:noreply,
             socket
             |> cancel_oauth_poll_timer()
             |> assign(
               oauth_link_flow: flow,
               oauth_link_authorization_url: authorization_url,
               oauth_link_result: %{message: "Browser authorization pending"},
               oauth_link_error: nil,
               oauth_link_pool_id: pool.id,
               oauth_link_form: oauth_link_form(pool.id)
             )}

          {:error, reason} ->
            {:noreply, assign_oauth_error(socket, reason)}
        end
    end
  end

  def handle_event("start_oauth_device", params, socket) do
    case selected_oauth_pool(socket, params) do
      nil ->
        {:noreply, assign_oauth_error(socket, OAuthCallback.safe_error(:unauthorized_pool))}

      pool ->
        case Upstreams.start_device_oauth(
               socket.assigns.current_scope,
               pool,
               oauth_start_opts(socket)
             ) do
          {:ok, %{flow: %OAuthFlow{} = flow}} ->
            {:noreply,
             socket
             |> assign(
               oauth_link_flow: flow,
               oauth_link_authorization_url: nil,
               oauth_link_result: %{message: "Device authorization pending"},
               oauth_link_error: nil,
               oauth_link_pool_id: pool.id,
               oauth_link_form: oauth_link_form(pool.id)
             )
             |> schedule_oauth_device_poll(flow)}

          {:error, reason} ->
            {:noreply, assign_oauth_error(socket, reason)}
        end
    end
  end

  def handle_event("submit_oauth_callback", %{"oauth_link" => oauth_params}, socket) do
    callback_url = Map.get(oauth_params, "callback_url", "")

    case socket.assigns.oauth_link_flow do
      %OAuthFlow{id: flow_id} ->
        case Upstreams.complete_browser_oauth(
               socket.assigns.current_scope,
               flow_id,
               callback_url
             ) do
          {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
            {:noreply, complete_oauth_link(socket, flow)}

          {:ok, %{flow: %OAuthFlow{} = flow}} ->
            {:noreply,
             assign(socket,
               oauth_link_flow: flow,
               oauth_link_form: oauth_link_form(socket.assigns.oauth_link_pool_id)
             )}

          {:error, reason} ->
            {:noreply, assign_oauth_error(socket, reason)}
        end

      nil ->
        {:noreply, assign_oauth_error(socket, OAuthCallback.safe_error(:flow_not_pending))}
    end
  end

  def handle_event("cancel_oauth_link", _params, socket) do
    socket = cancel_oauth_poll_timer(socket)

    case socket.assigns.oauth_link_flow do
      %OAuthFlow{id: flow_id, status: "pending"} ->
        case Upstreams.cancel_oauth_flow(socket.assigns.current_scope, flow_id) do
          {:ok, _flow} ->
            {:noreply, close_oauth_link_dialog(socket)}

          {:error, reason} ->
            {:noreply, assign_oauth_error(socket, reason)}
        end

      _flow ->
        {:noreply, close_oauth_link_dialog(socket)}
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
         UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
       )}
    end
  end

  def handle_event("cancel_auth_json_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :auth_json, ref)}
  end

  def handle_event("open_rename_account", %{"id" => identity_id}, socket) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      %{identity: %UpstreamIdentity{} = identity} = account ->
        {:noreply,
         socket
         |> close_saved_reset_policy_dialog()
         |> assign(
           renaming_account: account,
           rename_account_form: rename_account_form(identity)
         )}

      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}
    end
  end

  def handle_event("cancel_rename_account", _params, socket) do
    {:noreply, close_rename_account_dialog(socket)}
  end

  def handle_event("open_saved_reset_policy", %{"id" => identity_id}, socket) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      account ->
        {:noreply,
         socket
         |> close_auth_json_dialog()
         |> close_rename_account_dialog()
         |> close_oauth_link_dialog()
         |> assign(
           editing_saved_reset_policy: account,
           saved_reset_policy_form: saved_reset_policy_form(account.saved_reset_policy),
           confirming_saved_reset_redemption: nil
         )}
    end
  end

  def handle_event("cancel_saved_reset_policy", _params, socket) do
    {:noreply, close_saved_reset_policy_dialog(socket)}
  end

  def handle_event("validate_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :saved_reset_policy_form,
       saved_reset_policy_form(current_saved_reset_policy(socket), params, :validate)
     )}
  end

  def handle_event("open_saved_reset_redemption_confirmation", %{"id" => identity_id}, socket) do
    case socket.assigns.editing_saved_reset_policy do
      %{identity: %UpstreamIdentity{id: ^identity_id}} = account ->
        if account.saved_reset_redemption_action.available? do
          {:noreply, assign(socket, :confirming_saved_reset_redemption, account)}
        else
          {:noreply, put_flash(socket, :error, account.saved_reset_redemption_action.reason)}
        end

      _account ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}
    end
  end

  def handle_event("cancel_saved_reset_redemption", _params, socket) do
    {:noreply, assign(socket, :confirming_saved_reset_redemption, nil)}
  end

  def handle_event("redeem_saved_reset", %{"id" => identity_id}, socket) do
    case socket.assigns.confirming_saved_reset_redemption do
      %{identity: %UpstreamIdentity{id: ^identity_id}} = account ->
        if account.saved_reset_redemption_action.available? do
          enqueue_saved_reset_redemption(socket, account)
        else
          {:noreply, put_flash(socket, :error, account.saved_reset_redemption_action.reason)}
        end

      _account ->
        {:noreply, put_flash(socket, :error, "Confirm saved reset redemption before continuing")}
    end
  end

  def handle_event("save_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    case socket.assigns.editing_saved_reset_policy do
      %{identity: %UpstreamIdentity{id: identity_id}} ->
        changeset =
          saved_reset_policy_changeset(current_saved_reset_policy(socket), params, :validate)

        if changeset.valid? do
          save_saved_reset_policy(socket, identity_id, changeset)
        else
          {:noreply, assign_saved_reset_policy_form(socket, changeset)}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}
    end
  end

  def handle_event("validate_rename_account", %{"rename" => rename_params}, socket) do
    {:noreply,
     assign(
       socket,
       :rename_account_form,
       rename_account_form(socket.assigns.renaming_account, rename_params, :validate)
     )}
  end

  def handle_event("rename_account", %{"rename" => rename_params}, socket) do
    case socket.assigns.renaming_account do
      %{identity: %UpstreamIdentity{} = identity} ->
        do_rename_account(socket, identity, rename_params)

      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}
    end
  end

  def handle_event("pause_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      &Upstreams.pause_account_for_scope/3,
      "Upstream account paused"
    )
  end

  def handle_event("reactivate_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      &Upstreams.reactivate_account_for_scope/3,
      "Upstream account reactivated"
    )
  end

  def handle_event("delete_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      &Upstreams.soft_delete_account_for_scope/3,
      "Upstream account deleted"
    )
  end

  def handle_event("refresh_account", %{"id" => identity_id}, socket) do
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id,
           trigger_kind: "admin_upstreams_live"
         ) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: "Token refresh is already queued", else: "Token refresh queued"

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> reload_upstreams()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp save_saved_reset_policy(socket, identity_id, changeset) do
    attrs =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:trigger_kind, "admin_upstreams_live")

    case Upstreams.update_saved_reset_policy_for_scope(
           socket.assigns.current_scope,
           identity_id,
           attrs
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved reset policy updated")
         |> close_saved_reset_policy_dialog()
         |> reload_upstreams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_saved_reset_policy_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp assign_saved_reset_policy_form(socket, changeset) do
    assign(
      socket,
      :saved_reset_policy_form,
      Phoenix.Component.to_form(changeset, as: :saved_reset_policy)
    )
  end

  defp enqueue_saved_reset_redemption(socket, account) do
    with {:ok, pool_id} <- saved_reset_redemption_pool_id(account),
         {:ok, %{job: job}} <-
           Upstreams.enqueue_saved_reset_redemption_for_scope(
             socket.assigns.current_scope,
             account.identity.id,
             pool_id,
             trigger_kind: "admin_upstreams_live"
           ) do
      message =
        if job.conflict?,
          do: "Saved reset redemption is already queued",
          else: "Saved reset redemption queued"

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> assign(:confirming_saved_reset_redemption, nil)
       |> reload_upstreams()
       |> refresh_editing_saved_reset_policy(account.identity.id)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp saved_reset_redemption_pool_id(%{assignments: [%{pool_id: pool_id} | _assignments]})
       when is_binary(pool_id),
       do: {:ok, pool_id}

  defp saved_reset_redemption_pool_id(_account),
    do: {:error, %{message: "Saved reset redemption requires a Pool assignment"}}

  defp refresh_editing_saved_reset_policy(socket, identity_id) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      nil -> close_saved_reset_policy_dialog(socket)
      account -> assign(socket, :editing_saved_reset_policy, account)
    end
  end

  defp do_rename_account(socket, %UpstreamIdentity{} = identity, rename_params) do
    case Upstreams.rename_account_for_scope(
           socket.assigns.current_scope,
           identity.id,
           rename_params
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Upstream account renamed")
         |> close_rename_account_dialog()
         |> reload_upstreams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           rename_account_form: Phoenix.Component.to_form(changeset, as: :rename),
           renaming_account: socket.assigns.renaming_account
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp do_import_auth_json(socket, pool, auth_json_params, content) do
    case Upstreams.import_codex_auth_json(socket.assigns.current_scope, pool, content) do
      {:ok, %{status: :created}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json imported")
         |> assign(:auth_json_form, UpstreamAuthJsonImport.empty_form())
         |> assign(:importing_auth_json, false)
         |> reload_upstreams()}

      {:ok, %{status: :existing}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json matched an existing account; tokens updated")
         |> assign(:auth_json_form, UpstreamAuthJsonImport.empty_form())
         |> assign(:importing_auth_json, false)
         |> reload_upstreams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(:importing_auth_json, true)
         |> assign(:auth_json_form, Phoenix.Component.to_form(changeset, as: :auth_json))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:importing_auth_json, true)
         |> assign(
           :auth_json_form,
           UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
         )}
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
      <UpstreamPageComponents.upstreams_page
        pools={@pools}
        pool_options={@pool_options}
        dialog_pool_options={@dialog_pool_options}
        filter_form={@filter_form}
        filter_values={@filter_values}
        pool_filter_options={@pool_filter_options}
        status_options={@status_options}
        auth_json_form={@auth_json_form}
        auth_json_upload_limit_label={@auth_json_upload_limit_label}
        importing_auth_json={@importing_auth_json}
        oauth_linking={@oauth_linking}
        oauth_link_mode={@oauth_link_mode}
        oauth_link_target_account={@oauth_link_target_account}
        oauth_link_form={@oauth_link_form}
        oauth_link_flow={@oauth_link_flow}
        oauth_link_authorization_url={@oauth_link_authorization_url}
        oauth_link_result={@oauth_link_result}
        oauth_link_error={@oauth_link_error}
        renaming_account={@renaming_account}
        rename_account_form={@rename_account_form}
        editing_saved_reset_policy={@editing_saved_reset_policy}
        saved_reset_policy_form={@saved_reset_policy_form}
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        upstream_accounts={@upstream_accounts}
        uploads={@uploads}
        datetime_preferences={@datetime_preferences}
      />
    </AdminComponents.admin_shell>
    """
  end

  defp lifecycle_action(socket, identity_id, operation, success_message) do
    case operation.(socket.assigns.current_scope, identity_id, %{reason: "admin_upstreams_live"}) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message)
         |> reload_upstreams()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp load_upstreams(socket, params) do
    pools = Pools.list_visible_pools(socket.assigns.current_scope)
    filter_values = UpstreamFilterForm.filter_values(params, pools)
    filtered_pools = filtered_pools(pools, filter_values)

    datetime_preferences = DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user)

    upstream_accounts =
      UpstreamAccountsReadModel.list_visible_accounts(
        socket.assigns.current_scope,
        filtered_pools,
        filter_values,
        datetime_preferences
      )

    socket =
      socket
      |> cancel_upstreams_reload_timer()
      |> maybe_subscribe_pool_events(filtered_pools)

    assign(socket,
      pools: pools,
      pool_options: pool_options(pools),
      dialog_pool_options: dialog_pool_options(pools),
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools),
      filter_values: filter_values,
      filter_form: UpstreamFilterForm.filter_form(filter_values),
      status_options: UpstreamFilterForm.status_options(),
      upstream_accounts: upstream_accounts
    )
  end

  defp reload_upstreams(socket), do: load_upstreams(socket, socket.assigns.filter_values)

  defp poll_oauth_device(socket, flow_id) do
    case Upstreams.poll_device_oauth(socket.assigns.current_scope, flow_id) do
      {:ok, %{status: :completed, flow: %OAuthFlow{} = flow}} ->
        {:noreply, complete_oauth_link(socket, flow)}

      {:ok, %{status: :pending, flow: %OAuthFlow{} = flow}} ->
        {:noreply,
         socket
         |> assign(
           oauth_link_flow: flow,
           oauth_link_authorization_url: nil,
           oauth_link_result: %{message: "Device authorization pending"},
           oauth_link_error: nil,
           oauth_link_form: oauth_link_form(socket.assigns.oauth_link_pool_id)
         )
         |> schedule_oauth_device_poll(flow)}

      {:ok, %{flow: %OAuthFlow{} = flow}} ->
        {:noreply,
         assign(socket,
           oauth_link_flow: flow,
           oauth_link_form: oauth_link_form(socket.assigns.oauth_link_pool_id)
         )}

      {:error, reason} ->
        {:noreply, assign_oauth_error(socket, reason)}
    end
  end

  defp complete_oauth_link(socket, %OAuthFlow{} = flow) do
    socket
    |> cancel_oauth_poll_timer()
    |> assign(
      oauth_link_flow: flow,
      oauth_link_authorization_url: nil,
      oauth_link_result: %{message: oauth_complete_message(socket)},
      oauth_link_error: nil,
      oauth_link_form: oauth_link_form(socket.assigns.oauth_link_pool_id)
    )
    |> reload_upstreams()
  end

  @spec oauth_complete_message(Phoenix.LiveView.Socket.t()) :: String.t()
  defp oauth_complete_message(socket) do
    if oauth_relink_mode?(socket), do: "OpenAI account relinked", else: "OpenAI account linked"
  end

  defp schedule_oauth_device_poll(
         socket,
         %OAuthFlow{flow_kind: "device", status: "pending", interval_seconds: interval_seconds} =
           flow
       ) do
    socket = cancel_oauth_poll_timer(socket)
    delay_ms = max(positive_integer(interval_seconds, 5) * 1_000, 1_000)
    timer = Process.send_after(self(), {:poll_oauth_device, flow.id}, delay_ms)
    assign(socket, :oauth_link_poll_timer, timer)
  end

  defp schedule_oauth_device_poll(socket, _flow), do: socket

  defp cancel_oauth_poll_timer(socket) do
    if is_reference(socket.assigns[:oauth_link_poll_timer]) do
      Process.cancel_timer(socket.assigns.oauth_link_poll_timer, async: false, info: false)
    end

    assign(socket, :oauth_link_poll_timer, nil)
  end

  defp selected_oauth_pool(socket, params) do
    if oauth_relink_mode?(socket) do
      selected_pool(socket.assigns.pools, socket.assigns.oauth_link_pool_id)
    else
      selected_oauth_link_pool(socket, params)
    end
  end

  defp selected_oauth_link_pool(socket, params) do
    pool_id = oauth_link_pool_id_from_params(params) || socket.assigns.oauth_link_pool_id
    selected_pool(socket.assigns.pools, pool_id)
  end

  @spec oauth_start_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  defp oauth_start_opts(socket) do
    opts = [metadata: %{"source" => "admin_upstreams"}]

    case socket.assigns.oauth_link_target_account do
      %{identity: %{id: identity_id}} when is_binary(identity_id) ->
        Keyword.put(opts, :upstream_identity_id, identity_id)

      _account ->
        opts
    end
  end

  @spec oauth_relink_pool_id(map()) :: {:ok, String.t()} | {:error, String.t()}
  defp oauth_relink_pool_id(%{identity: %{status: "deleted"}}),
    do: {:error, "OAuth relink is not available: deleted accounts cannot be relinked"}

  defp oauth_relink_pool_id(%{assignments: [%{pool_id: pool_id} | _assignments]})
       when is_binary(pool_id),
       do: {:ok, pool_id}

  defp oauth_relink_pool_id(_account),
    do: {:error, "OAuth relink is not available: assign this account to a visible Pool first"}

  @spec oauth_relink_mode?(Phoenix.LiveView.Socket.t()) :: boolean()
  defp oauth_relink_mode?(%{assigns: %{oauth_link_mode: :relink}}), do: true
  defp oauth_relink_mode?(_socket), do: false

  defp oauth_link_pool_id_from_params(%{"oauth_link" => %{"pool_id" => pool_id}})
       when is_binary(pool_id),
       do: pool_id

  defp oauth_link_pool_id_from_params(%{"pool-id" => pool_id}) when is_binary(pool_id),
    do: pool_id

  defp oauth_link_pool_id_from_params(_params), do: nil

  defp oauth_link_pool_id_for_open(pools, %{"pool-id" => pool_id}) do
    case selected_pool(pools, pool_id) do
      nil -> ""
      _pool -> pool_id
    end
  end

  defp oauth_link_pool_id_for_open(_pools, _params), do: ""

  defp assign_oauth_error(socket, reason) do
    assign(socket,
      oauth_link_error: %{message: error_message(reason)},
      oauth_link_result: nil,
      oauth_link_form: oauth_link_form(socket.assigns.oauth_link_pool_id)
    )
  end

  defp oauth_link_form(pool_id \\ "", callback_url \\ "") do
    Phoenix.Component.to_form(
      %{
        "pool_id" => pool_id,
        "callback_url" => callback_url
      },
      as: :oauth_link
    )
  end

  defp oauth_flow_id?(%OAuthFlow{id: id}, id), do: true
  defp oauth_flow_id?(_flow, _id), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp schedule_upstreams_reload(socket) do
    if is_reference(socket.assigns[:upstreams_reload_timer]) do
      socket
    else
      timer =
        Process.send_after(
          self(),
          :reload_upstreams_from_events,
          @upstreams_reload_debounce_ms
        )

      assign(socket, :upstreams_reload_timer, timer)
    end
  end

  defp cancel_upstreams_reload_timer(socket) do
    if is_reference(socket.assigns[:upstreams_reload_timer]) do
      Process.cancel_timer(socket.assigns.upstreams_reload_timer, async: false, info: false)
    end

    assign(socket, :upstreams_reload_timer, nil)
  end

  defp filtered_pools(pools, %{"pool_id" => pool_id}) when is_binary(pool_id) and pool_id != "" do
    Enum.filter(pools, &(&1.id == pool_id))
  end

  defp filtered_pools(pools, _filter_values), do: pools

  defp maybe_subscribe_pool_events(socket, pools) do
    pools
    |> PoolEventSubscriptions.pool_id_set()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
      socket
    end)
  end

  defp selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  defp selected_pool(_pools, _pool_id), do: nil

  defp auth_json_form_for_open(pools, %{"pool-id" => pool_id}) do
    case selected_pool(pools, pool_id) do
      nil -> UpstreamAuthJsonImport.empty_form()
      _pool -> UpstreamAuthJsonImport.form_for_pool(pool_id)
    end
  end

  defp auth_json_form_for_open(_pools, _params), do: UpstreamAuthJsonImport.empty_form()

  defp find_account(accounts, identity_id) do
    Enum.find(accounts, &(&1.identity.id == identity_id))
  end

  defp pool_options(pools) do
    pools
    |> Enum.map(&{pool_name(&1), &1.id})
    |> case do
      [] -> [{"No active Pools available", ""}]
      options -> options
    end
  end

  defp pool_name(nil), do: "Unknown Pool"
  defp pool_name(pool), do: pool.name

  defp dialog_pool_options(pools) do
    pools
    |> Enum.map(&{pool_name(&1), &1.id})
    |> case do
      [] -> [{"No active Pools available", ""}]
      options -> options
    end
  end

  defp close_auth_json_dialog(socket) do
    socket
    |> cancel_auth_json_upload_entries()
    |> assign(
      importing_auth_json: false,
      auth_json_form: UpstreamAuthJsonImport.empty_form()
    )
  end

  defp close_rename_account_dialog(socket) do
    assign(socket,
      renaming_account: nil,
      rename_account_form: nil
    )
  end

  @spec close_saved_reset_policy_dialog(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  defp close_saved_reset_policy_dialog(socket) do
    assign(socket,
      editing_saved_reset_policy: nil,
      saved_reset_policy_form: saved_reset_policy_form(%{}),
      confirming_saved_reset_redemption: nil
    )
  end

  defp close_oauth_link_dialog(socket) do
    socket
    |> cancel_oauth_poll_timer()
    |> assign(
      oauth_linking: false,
      oauth_link_mode: :link,
      oauth_link_target_account: nil,
      oauth_link_form: oauth_link_form(),
      oauth_link_pool_id: "",
      oauth_link_flow: nil,
      oauth_link_authorization_url: nil,
      oauth_link_result: nil,
      oauth_link_error: nil
    )
  end

  defp rename_account_form(account_or_identity, attrs \\ %{}, action \\ nil)

  defp rename_account_form(%{identity: %UpstreamIdentity{} = identity}, attrs, action),
    do: rename_account_form(identity, attrs, action)

  defp rename_account_form(%UpstreamIdentity{} = identity, attrs, action) do
    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Map.put(:action, action)
    |> Phoenix.Component.to_form(as: :rename)
  end

  defp rename_account_form(nil, _attrs, _action), do: nil

  @spec saved_reset_policy_form(map(), map(), atom() | nil) :: Phoenix.HTML.Form.t()
  defp saved_reset_policy_form(policy, attrs \\ %{}, action \\ nil) do
    policy
    |> saved_reset_policy_changeset(attrs, action)
    |> Phoenix.Component.to_form(as: :saved_reset_policy)
  end

  @spec saved_reset_policy_changeset(map(), map(), atom() | nil) :: Ecto.Changeset.t()
  defp saved_reset_policy_changeset(policy, attrs, action) do
    data = %{
      auto_redeem_enabled: Map.get(policy, :enabled?, false),
      trigger_mode: Map.get(policy, :trigger_mode, "blocked"),
      quota_threshold_percent: Map.get(policy, :quota_threshold_percent, 95),
      min_blocked_minutes: Map.get(policy, :min_blocked_minutes, 60),
      keep_credits: Map.get(policy, :keep_credits, 0)
    }

    {data,
     %{
       auto_redeem_enabled: :boolean,
       trigger_mode: :string,
       quota_threshold_percent: :integer,
       min_blocked_minutes: :integer,
       keep_credits: :integer
     }}
    |> Ecto.Changeset.cast(attrs, [
      :auto_redeem_enabled,
      :trigger_mode,
      :quota_threshold_percent,
      :min_blocked_minutes,
      :keep_credits
    ])
    |> Ecto.Changeset.validate_inclusion(:trigger_mode, ["blocked", "threshold"])
    |> Ecto.Changeset.validate_number(:quota_threshold_percent,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> Ecto.Changeset.validate_number(:min_blocked_minutes, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:keep_credits, greater_than_or_equal_to: 0)
    |> Map.put(:action, action)
  end

  @spec current_saved_reset_policy(Phoenix.LiveView.Socket.t()) :: map()
  defp current_saved_reset_policy(socket) do
    case socket.assigns.editing_saved_reset_policy do
      %{saved_reset_policy: policy} when is_map(policy) -> policy
      _account -> %{}
    end
  end

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

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Operation failed"
end
