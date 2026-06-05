defmodule CodexPooler.JobsQueryBudgetHelper do
  @moduledoc false

  alias CodexPooler.Repo

  def capture_repo_queries(fun, opts \\ []) when is_function(fun, 0) do
    test_pid = self()
    repo = Keyword.get(opts, :repo, Repo)
    idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, 10)
    handler_id = {__MODULE__, test_pid, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_repo_query_event/4,
        {handler_id, test_pid, repo}
      )

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [], idle_timeout_ms)}
    after
      :telemetry.detach(handler_id)
    end
  end

  def handle_repo_query_event(_event, measurements, metadata, {handler_id, test_pid, repo}) do
    if metadata[:repo] == repo do
      send(test_pid, {handler_id, format_repo_query_event(measurements, metadata)})
    end
  end

  def summarize_by_source_and_command(events) do
    Enum.frequencies_by(events, &{&1.source, &1.command})
  end

  def write_report!(path, entries) when is_list(entries) do
    expanded_path = Path.expand(path, File.cwd!())
    File.mkdir_p!(Path.dirname(expanded_path))
    File.write!(expanded_path, render_report(entries))
    expanded_path
  end

  defp drain_repo_query_events(handler_id, events, idle_timeout_ms) do
    receive do
      {^handler_id, event} ->
        drain_repo_query_events(handler_id, [event | events], idle_timeout_ms)
    after
      idle_timeout_ms -> Enum.reverse(events)
    end
  end

  defp format_repo_query_event(measurements, metadata) do
    %{
      source: normalize_source(metadata[:source]),
      command: query_command(metadata[:query]),
      query_time: measurements[:query_time],
      queue_time: measurements[:queue_time],
      decode_time: measurements[:decode_time],
      total_time: measurements[:total_time]
    }
  end

  defp normalize_source(nil), do: "unknown"
  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(source), do: to_string(source)

  defp query_command(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      nil -> "UNKNOWN"
      command -> String.upcase(command)
    end
  end

  defp query_command(_query), do: "UNKNOWN"

  defp render_report(entries) do
    entries
    |> Enum.map(&render_entry/1)
    |> Enum.join("\n\n")
  end

  defp render_entry(%{flow_name: flow_name, events: events} = entry) do
    metrics = entry |> Map.get(:metrics, %{}) |> Map.put_new(:queries, length(events))
    notes = Map.get(entry, :notes, [])

    metric_text =
      metrics
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    breakdown_text =
      events
      |> summarize_by_source_and_command()
      |> Enum.sort_by(fn {{source, command}, _count} -> {source, command} end)
      |> case do
        [] ->
          ["  source=none command=none count=0"]

        rows ->
          Enum.map(rows, fn {{source, command}, count} ->
            "  source=#{source} command=#{command} count=#{count}"
          end)
      end
      |> Enum.join("\n")

    notes_text =
      notes
      |> List.wrap()
      |> Enum.map_join("\n", &"note=#{&1}")

    [
      "flow=#{flow_name} #{metric_text}",
      "breakdown:",
      breakdown_text,
      notes_text
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
end
