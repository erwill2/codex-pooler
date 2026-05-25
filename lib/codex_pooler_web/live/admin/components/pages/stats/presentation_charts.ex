defmodule CodexPoolerWeb.Admin.StatsPresentation.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :requests, :list, required: true
  attr :tokens, :list, required: true

  def traffic_charts(assigns) do
    ~H"""
    <section class="grid min-w-0 gap-4">
      <.bar_chart
        id="stats-traffic-chart"
        title="Requests over time"
        description="Requests grouped by the selected range."
        points={request_chart_points(@requests)}
        unit="requests"
      />
      <.bar_chart
        id="stats-token-chart"
        title="Tokens over time"
        description="Settled tokens grouped by the selected range."
        points={token_chart_points(@tokens)}
        unit="tokens"
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :points, :list, required: true
  attr :unit, :string, required: true

  def bar_chart(assigns) do
    assigns = assign(assigns, :chart, apex_chart_model(assigns.points, assigns.unit))

    ~H"""
    <section id={@id} class="min-w-0 rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="grid gap-1">
          <h2 id={"#{@id}-heading"} class="text-lg font-semibold text-base-content">{@title}</h2>
          <p id={"#{@id}-summary"} class="text-sm leading-6 text-base-content/70">
            {@description}
          </p>
        </div>
        <span id={"#{@id}-total"} class="font-mono text-sm font-semibold tabular-nums">
          {@chart.total_label}
        </span>
      </div>
      <div
        id={"#{@id}-plot"}
        class="admin-apex-bar-chart mt-4 w-full"
        phx-hook="ApexTimeSeriesChart"
        role="img"
        aria-labelledby={"#{@id}-title #{@id}-desc"}
        data-chart-categories={@chart.categories}
        data-chart-series={@chart.series}
        data-chart-unit={@unit}
        data-chart-height="320"
        data-chart-color="var(--color-primary)"
        data-chart-labels="true"
      >
      </div>
      <p id={"#{@id}-title"} class="sr-only">{@title}</p>
      <p id={"#{@id}-desc"} class="sr-only">{chart_description(@points, @unit)}</p>
      <ul class="sr-only">
        <li :for={point <- @points}>{point.label}: {point.value} {@unit}</li>
      </ul>
    </section>
    """
  end

  defp chart_description(points, unit) do
    total = Enum.reduce(points, 0, &(&1.value + &2))
    "#{length(points)} time buckets with #{total} total #{unit}."
  end

  defp request_chart_points(rows) do
    Enum.map(rows, &%{label: format_bucket(&1.bucket), value: &1.requests})
  end

  defp token_chart_points(rows) do
    Enum.map(rows, &%{label: format_bucket(&1.bucket), value: &1.total_tokens})
  end

  defp apex_chart_model(points, unit) do
    values = Enum.map(points, &max(&1.value || 0, 0))
    total = Enum.sum(values)

    %{
      categories: Jason.encode!(Enum.map(points, & &1.label)),
      series: Jason.encode!([%{name: humanize(unit), data: values}]),
      total_label: "#{format_integer(total)} #{unit}"
    }
  end

  defp format_bucket(<<date::binary-size(10), "T", hour::binary-size(2), ":00:00Z">>),
    do: String.slice(date, 5, 5) <> " " <> hour <> ":00"

  defp format_bucket(
         <<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>
       ),
       do: month <> "-" <> day

  defp format_bucket(bucket), do: to_string(bucket)

  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
