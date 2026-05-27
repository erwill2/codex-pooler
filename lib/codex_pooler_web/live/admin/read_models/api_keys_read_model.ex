defmodule CodexPoolerWeb.Admin.ApiKeysReadModel do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPoolerWeb.Admin.ApiKeyPolicyForm
  alias CodexPoolerWeb.Admin.OptionLoaderFallback

  @type data_load_warning :: map()
  @type option :: {String.t(), Ecto.UUID.t() | String.t()}
  @type pool_lookup :: %{optional(Ecto.UUID.t()) => Pool.t()}
  @type usage_summary :: map()
  @type pool_group :: %{
          required(:id) => Ecto.UUID.t() | nil,
          required(:dom_id) => String.t(),
          required(:name) => String.t(),
          required(:api_keys) => [APIKey.t()],
          required(:count_label) => String.t()
        }
  @type page_state :: %{
          required(:pools) => [Pool.t()],
          required(:pool_lookup) => pool_lookup(),
          required(:api_keys) => [APIKey.t()],
          required(:api_key_usage_summaries) => %{optional(Ecto.UUID.t()) => usage_summary()},
          required(:api_key_pool_groups) => [pool_group()],
          required(:pool_options) => [option()],
          required(:data_load_warnings) => [data_load_warning()]
        }

  @spec load(term()) :: page_state()
  def load(scope) do
    pools = Pools.list_visible_pools(scope)
    pool_lookup = Map.new(pools, &{&1.id, &1})
    {api_keys, data_load_warnings} = list_api_keys(scope)
    usage_summaries = usage_summaries(api_keys)

    %{
      pools: pools,
      pool_lookup: pool_lookup,
      api_keys: api_keys,
      api_key_usage_summaries: usage_summaries,
      api_key_pool_groups: pool_groups(pools, pool_lookup, api_keys),
      pool_options: pool_options(pools),
      data_load_warnings: data_load_warnings
    }
  end

  @spec selected_pool([Pool.t()], term()) :: Pool.t() | nil
  def selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  def selected_pool(_pools, _pool_id), do: nil

  @spec usage_for_params(map()) :: usage_summary()
  def usage_for_params(%{"id" => api_key_id, "pool_id" => pool_id}) do
    case {blank_to_nil(api_key_id), blank_to_nil(pool_id)} do
      {nil, _pool_id} -> empty_usage()
      {_api_key_id, nil} -> empty_usage()
      {api_key_id, pool_id} -> load_api_key_usage(pool_id, api_key_id)
    end
  end

  def usage_for_params(_params), do: empty_usage()

  @spec empty_usage() :: usage_summary()
  def empty_usage do
    %{
      available?: false,
      request_count: 0,
      total_tokens: 0,
      cached_input_tokens: 0,
      limits: []
    }
  end

  @spec model_selector_state(Pool.t() | nil, map()) :: map()
  def model_selector_state(nil, _params), do: empty_model_selector_state()

  def model_selector_state(%Pool{} = pool, params) do
    Catalog.api_key_model_selector_state(pool, ApiKeyPolicyForm.model_selector_attrs(params))
  end

  @spec empty_model_selector_state() :: map()
  def empty_model_selector_state do
    %{
      catalog: %{status: :unavailable, message: "Select a Pool first", severity: :warning},
      mode: :all_models,
      options: [],
      selected_options: [],
      selected_unavailable_chips: [],
      manual_chips: [],
      selected_identifiers: [],
      manual_identifiers: [],
      warnings: []
    }
  end

  @spec pool_options([Pool.t()]) :: [option()]
  def pool_options([]), do: [{"No active Pools available", ""}]

  def pool_options(pools) do
    Enum.map(pools, &{&1.name, &1.id})
  end

  @spec pool_groups([Pool.t()], pool_lookup(), [APIKey.t()]) :: [pool_group()]
  def pool_groups(pools, pool_lookup, api_keys) do
    api_keys_by_pool_id = Enum.group_by(api_keys, & &1.pool_id)

    known_groups =
      pools
      |> Enum.flat_map(fn pool ->
        pool_api_keys = Map.get(api_keys_by_pool_id, pool.id, [])

        if pool_api_keys == [] do
          []
        else
          [
            %{
              id: pool.id,
              dom_id: pool_dom_id(pool),
              name: pool.name,
              api_keys: pool_api_keys,
              count_label: api_key_count_label(length(pool_api_keys))
            }
          ]
        end
      end)

    unknown_api_keys =
      Enum.reject(api_keys, fn api_key -> Map.has_key?(pool_lookup, api_key.pool_id) end)

    if unknown_api_keys == [] do
      known_groups
    else
      known_groups ++
        [
          %{
            id: nil,
            dom_id: "unknown-pool",
            name: "Unknown Pool",
            api_keys: unknown_api_keys,
            count_label: api_key_count_label(length(unknown_api_keys))
          }
        ]
    end
  end

  @spec model_policy_label(nil | [String.t()]) :: String.t()
  def model_policy_label(nil), do: "All models"
  def model_policy_label([]), do: "No models"
  def model_policy_label(models), do: Enum.join(models, ", ")

  @spec usage_present?(usage_summary() | nil) :: boolean()
  def usage_present?(usage) do
    positive_integer?(usage[:request_count]) or positive_integer?(usage[:total_tokens]) or
      positive_integer?(usage[:cached_input_tokens])
  end

  @spec row_usage_cost(usage_summary() | nil) :: String.t() | nil
  def row_usage_cost(%{total_cost_status: "priced", total_cost_usd: %Decimal{} = usd}) do
    "Cost $#{format_usd(usd)}"
  end

  def row_usage_cost(_usage), do: nil

  @spec format_integer(integer() | Decimal.t() | nil | term()) :: String.t()
  def format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer() |> format_integer()

  def format_integer(nil), do: "unknown"
  def format_integer(value), do: value |> to_string() |> blank_to_nil() || "unknown"

  @spec api_key_operator_notes(APIKey.t() | term()) :: String.t() | nil
  def api_key_operator_notes(%APIKey{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("operator_notes", Map.get(metadata, :operator_notes))
    |> blank_to_nil()
  end

  def api_key_operator_notes(_api_key), do: nil

  defp list_api_keys(scope) do
    case Access.list_api_keys(scope) do
      {:ok, api_keys} ->
        {api_keys, []}

      {:error, reason} ->
        empty_admin_options(:api_keys, reason, %{
          title: "API keys unavailable",
          message: "API key data could not be loaded. Empty results may be incomplete."
        })
    end
  end

  defp usage_summaries(api_keys) do
    api_keys
    |> Enum.map(& &1.id)
    |> Accounting.list_api_key_usage_summaries()
  end

  defp load_api_key_usage(pool_id, api_key_id) do
    case Accounting.build_api_key_self_usage(pool_id, api_key_id) do
      {:ok, usage} -> Map.put(usage, :available?, true)
      {:error, _reason} -> empty_usage()
    end
  end

  defp pool_dom_id(pool) do
    pool.slug
    |> dom_token()
    |> case do
      "" -> dom_token(pool.id)
      dom_id -> dom_id
    end
  end

  defp api_key_count_label(1), do: "1 key"
  defp api_key_count_label(count), do: "#{count} keys"

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp format_usd(%Decimal{} = usd) do
    usd
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> fixed_decimal_places(2)
  end

  defp fixed_decimal_places(value, places) do
    case String.split(value, ".", parts: 2) do
      [whole] -> whole <> "." <> String.duplicate("0", places)
      [whole, fraction] -> whole <> "." <> String.pad_trailing(fraction, places, "0")
    end
  end

  defp dom_token(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp empty_admin_options(loader, reason, warning) do
    OptionLoaderFallback.empty_options(
      :api_keys,
      loader,
      reason,
      warning,
      [:pool_not_found, :api_key_not_found]
    )
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end
end
