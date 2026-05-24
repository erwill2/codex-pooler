defmodule CodexPooler.Jobs.Options do
  @moduledoc false

  @spec job_options(keyword(), unique_keys: [atom()]) :: keyword()
  def job_options(opts, unique_keys: keys) do
    opts
    |> Keyword.take([:scheduled_at, :schedule_in])
    |> Keyword.put(
      :unique,
      Keyword.get(opts, :unique,
        fields: [:args, :queue, :worker],
        keys: keys,
        states: [:scheduled, :available, :executing, :retryable],
        period: {7, :days}
      )
    )
  end
end
