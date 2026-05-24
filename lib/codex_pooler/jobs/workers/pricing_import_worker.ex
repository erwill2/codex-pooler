defmodule CodexPooler.Jobs.PricingImportWorker do
  @moduledoc """
  Refreshes OpenAI pricing snapshots from the published JSON catalog.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 3,
    tags: ["pricing_import"],
    unique: [
      fields: [:worker, :queue],
      states: [:scheduled, :available, :executing, :retryable],
      period: {1, :hour}
    ]

  alias CodexPooler.{Catalog, InstanceSettings}

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{}}) do
    InstanceSettings.current()
    |> openai_pricing_url()
    |> import_pricing()
  end

  defp openai_pricing_url(%{catalog: %{openai_pricing_url: source_url}}), do: source_url

  defp import_pricing(source_url) when not is_binary(source_url) do
    {:error, :openai_pricing_url_required}
  end

  defp import_pricing(source_url) when is_binary(source_url) do
    case Catalog.import_openai_pricing_from_url(source_url) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
