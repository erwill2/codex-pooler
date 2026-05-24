defmodule CodexPoolerWeb.Admin.StatsPresentation.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  @chart_width 640
  @chart_height 320
  @chart_top 20
  @chart_right 16
  @chart_bottom 72
  @chart_left 52
  @chart_plot_width @chart_width - @chart_left - @chart_right
  @chart_plot_height @chart_height - @chart_top - @chart_bottom

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
    assigns = assign(assigns, :chart, chart_model(assigns.points))

    ~H"""
    <section id={@id} class="min-w-0 rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="grid gap-1">
        <h2 id={"#{@id}-heading"} class="text-lg font-semibold text-base-content">{@title}</h2>
        <p id={"#{@id}-summary"} class="text-sm leading-6 text-base-content/70">{@description}</p>
      </div>
      <div
        id={"#{@id}-plot"}
        class="mt-4 w-full"
        role="img"
        aria-labelledby={"#{@id}-title #{@id}-desc"}
        data-chart-unit={@unit}
      >
        <svg
          class="h-80 w-full overflow-visible"
          viewBox={"0 0 #{@chart.width} #{@chart.height}"}
          aria-hidden="true"
        >
          <g :for={tick <- @chart.ticks}>
            <line
              x1={@chart.left}
              x2={@chart.width - @chart.right}
              y1={tick.y}
              y2={tick.y}
              class="stroke-base-300"
              stroke-dasharray="3 5"
            />
            <text
              x={@chart.left - 10}
              y={tick.y + 4}
              text-anchor="end"
              class="fill-base-content/55 text-[10px] font-medium"
            >
              {tick.label}
            </text>
          </g>
          <line
            x1={@chart.left}
            x2={@chart.width - @chart.right}
            y1={@chart.bottom_axis}
            y2={@chart.bottom_axis}
            class="stroke-base-300"
          />
          <g :for={bar <- @chart.bars}>
            <rect
              :if={bar.height > 0}
              x={bar.x}
              y={bar.y}
              width={bar.width}
              height={bar.height}
              rx="4"
              class="fill-primary/85 transition-colors hover:fill-primary"
            >
              <title>{bar.label}: {format_integer(bar.value)} {@unit}</title>
            </rect>
            <line
              :if={bar.height == 0}
              x1={bar.x}
              x2={bar.x + bar.width}
              y1={@chart.bottom_axis}
              y2={@chart.bottom_axis}
              class="stroke-base-content/30"
            />
            <text
              x={bar.label_x}
              y={bar.label_y}
              text-anchor="end"
              transform={"rotate(-45 #{bar.label_x} #{bar.label_y})"}
              class="fill-base-content/60 text-[10px] font-medium"
            >
              {bar.label}
            </text>
          </g>
        </svg>
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

  defp chart_model(points) do
    max_value = chart_max_value(points)
    slot_width = @chart_plot_width / max(length(points), 1)
    gap = min(slot_width * 0.28, 10.0)
    bar_width = max(slot_width - gap, 2.0)

    bars =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        value = max(point.value || 0, 0)
        height = chart_bar_height(value, max_value)
        x = @chart_left + index * slot_width + gap / 2
        y = @chart_top + @chart_plot_height - height
        label_x = x + bar_width / 2
        label_y = @chart_top + @chart_plot_height + 22

        %{
          label: point.label,
          value: value,
          x: round_svg(x),
          y: round_svg(y),
          width: round_svg(bar_width),
          height: round_svg(height),
          label_x: round_svg(label_x),
          label_y: round_svg(label_y)
        }
      end)

    %{
      width: @chart_width,
      height: @chart_height,
      left: @chart_left,
      right: @chart_right,
      bottom_axis: @chart_top + @chart_plot_height,
      ticks: chart_ticks(max_value),
      bars: bars
    }
  end

  defp chart_max_value(points) do
    points
    |> Enum.map(&max(&1.value || 0, 0))
    |> Enum.max(fn -> 0 end)
    |> max(1)
  end

  defp chart_bar_height(0, _max_value), do: 0

  defp chart_bar_height(value, max_value) do
    value
    |> Kernel./(max_value)
    |> Kernel.*(@chart_plot_height)
    |> max(2.0)
  end

  defp chart_ticks(max_value) do
    for step <- 0..4 do
      value = max_value * step / 4
      y = @chart_top + @chart_plot_height - @chart_plot_height * step / 4

      %{label: format_axis_value(value), y: round_svg(y)}
    end
  end

  defp format_axis_value(value) when value >= 1_000_000,
    do: "#{format_axis_decimal(value / 1_000_000)}M"

  defp format_axis_value(value) when value >= 1_000,
    do: "#{format_axis_decimal(value / 1_000)}k"

  defp format_axis_value(value), do: value |> round() |> Integer.to_string()

  defp format_axis_decimal(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  defp round_svg(value) when is_integer(value), do: value
  defp round_svg(value), do: Float.round(value, 2)

  defp format_bucket(<<date::binary-size(10), "T", hour::binary-size(2), ":00:00Z">>),
    do: String.slice(date, 5, 5) <> " " <> hour <> ":00"

  defp format_bucket(
         <<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>
       ),
       do: month <> "-" <> day

  defp format_bucket(bucket), do: to_string(bucket)

  defp format_integer(nil), do: "0"
  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
end
