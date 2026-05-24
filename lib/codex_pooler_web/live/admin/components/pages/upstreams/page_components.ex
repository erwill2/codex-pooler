defmodule CodexPoolerWeb.Admin.UpstreamPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountCard
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonDialog

  attr :pools, :list, required: true
  attr :pool_options, :list, required: true
  attr :dialog_pool_options, :list, required: true
  attr :auth_json_form, :any, required: true
  attr :auth_json_upload_limit_label, :string, required: true
  attr :importing_auth_json, :boolean, required: true
  attr :upstream_accounts, :list, required: true
  attr :uploads, :map, required: true

  def upstreams_page(assigns) do
    ~H"""
    <section id="admin-upstreams-live" class="grid gap-6">
      <AdminComponents.page_header
        id="upstream-account-page-header"
        title="Upstreams"
        description="Import upstream auth.json, check readiness, and keep account access current."
      >
        <:actions>
          <AdminComponents.action_button
            :if={@pools == []}
            id="upstream-account-page-create-pool"
            icon="hero-server-stack"
            label="Create Pool"
            navigate={~p"/admin/pools"}
            size={:md}
            variant={:primary}
          />
          <AdminComponents.action_button
            :if={@pools != []}
            id="upstream-page-import-auth-json-action"
            icon="hero-document-arrow-up"
            label="Import auth.json"
            phx-click="open_import_auth_json"
            size={:md}
            variant={:primary}
          />
        </:actions>
      </AdminComponents.page_header>

      <UpstreamAuthJsonDialog.auth_json_import_dialog
        auth_json_form={@auth_json_form}
        importing_auth_json={@importing_auth_json}
        pool_options={@dialog_pool_options}
        upload={@uploads.auth_json}
        upload_limit_label={@auth_json_upload_limit_label}
      />

      <section id="upstream-account-surface" class="grid min-w-0 gap-4">
        <AdminComponents.empty_state
          :if={@upstream_accounts == []}
          id="upstream-account-empty-state"
          title={if @pools == [], do: "No Pools Found", else: "No upstream accounts"}
          description={
            if @pools == [],
              do: "Create a Pool before importing upstream auth.json.",
              else: "Import upstream auth.json to connect an account to a Pool."
          }
          icon="hero-cloud-arrow-up"
        >
          <:actions :if={@pools == []}>
            <AdminComponents.action_button
              id="upstream-empty-create-pool"
              icon="hero-server-stack"
              label="Create Pool"
              navigate={~p"/admin/pools"}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.empty_state>

        <.upstream_account_grid accounts={@upstream_accounts} />
      </section>
    </section>
    """
  end

  attr :accounts, :list, required: true

  defp upstream_account_grid(assigns) do
    ~H"""
    <div
      :if={@accounts != []}
      id="upstream-account-grid"
      class="grid gap-3 lg:grid-cols-2 2xl:grid-cols-3"
    >
      <UpstreamAccountCard.account_card
        :for={{account, account_index} <- Enum.with_index(@accounts)}
        account={account}
        account_index={account_index}
      />
    </div>
    """
  end
end
