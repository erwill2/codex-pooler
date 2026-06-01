defmodule CodexPooler.Dev.GatewayPerfWebsocketDriver do
  @moduledoc false

  @scenarios %{
    "ws-short-10c" => %{profile: "short-ok", expected: MapSet.new(["completed"])},
    "ws-long-10c" => %{
      profile: "long-ok",
      expected: MapSet.new(["completed", "duration_elapsed"])
    },
    "ws-disconnect-10c" => %{
      profile: "disconnect-midstream",
      expected: MapSet.new(["classified_disconnect"])
    },
    "ws-slow-first-event-10c" => %{
      profile: "slow-first-event",
      expected: MapSet.new(["completed", "classified_failure", "classified_disconnect"])
    }
  }

  @route_families ~w(backend v1 mixed)
  @default_model "gpt-5.5"
  @default_route_family "mixed"
  @correlation_header "x-codex-pooler-perf-scenario"
  @profile_header "x-gateway-perf-profile"
  @usage """
  Usage:
    mix run scripts/dev/gateway-perf-ws.exs -- --run-id RUN --base-url URL --api-key-env ENV --profile-manifest PATH --scenario SCENARIO --duration-seconds N --concurrency N --phase PHASE [options]

  Required options:
    --run-id RUN                 Stable run id used in tmp/gateway-perf/<run-id>/driver
    --base-url URL               Gateway or fake-upstream base URL, for example http://127.0.0.1:4000
    --api-key-env ENV            Environment variable name containing the Pool API key
    --profile-manifest PATH      Task 2 fake-upstream profile manifest path
    --scenario SCENARIO          ws-short-10c, ws-long-10c, ws-disconnect-10c, ws-slow-first-event-10c
    --duration-seconds N         Hard wall-clock bound for each connection
    --concurrency N              Number of concurrent websocket connections
    --phase PHASE                Free-form phase label written to metadata

  Options:
    --route-family FAMILY        backend, v1, or mixed (default: mixed)
    --model MODEL                Synthetic model id to send (default: gpt-5.5)
    --dry-run                    Validate CLI shape and write no traffic
    --help                       Print this help
  """

  @type scenario :: %{
          required(:profile) => String.t(),
          required(:expected) => MapSet.t(String.t())
        }
  @type config :: %{
          required(:run_id) => String.t(),
          required(:base_url) => String.t(),
          required(:api_key_env) => String.t(),
          required(:profile_manifest) => String.t(),
          required(:scenario) => String.t(),
          required(:scenario_config) => scenario(),
          required(:duration_seconds) => pos_integer(),
          required(:concurrency) => pos_integer(),
          required(:phase) => String.t(),
          required(:route_family) => String.t(),
          required(:model) => String.t(),
          required(:dry_run?) => boolean(),
          required(:driver_dir) => String.t(),
          required(:started_at) => DateTime.t(),
          required(:manifest_profile_found?) => boolean()
        }
  @type connection_result :: %{
          required(:connection_id) => String.t(),
          required(:route_family) => String.t(),
          required(:outcome) => String.t(),
          required(:messages_received) => non_neg_integer(),
          required(:clean_close?) => boolean(),
          required(:classified_disconnect?) => boolean(),
          required(:reconnect_attempts) => non_neg_integer(),
          required(:status) => String.t(),
          required(:duration_ms) => non_neg_integer(),
          optional(:error_code) => String.t(),
          optional(:close_code) => integer(),
          optional(:close_reason_class) => String.t()
        }

  @spec run([String.t()]) :: :ok | no_return()
  def run(args) when is_list(args) do
    case parse_args(args) do
      {:help, text} ->
        IO.write(text)

      {:ok, config} ->
        if config.dry_run? do
          print_dry_run(config)
        else
          run_live(config)
        end

      {:error, message} ->
        IO.puts(:stderr, "gateway-perf-ws: #{message}\n\n#{@usage}")
        System.halt(2)
    end
  end

  @spec parse_args([String.t()]) :: {:ok, config()} | {:help, String.t()} | {:error, String.t()}
  def parse_args(args) when is_list(args) do
    args = strip_mix_separator(args)

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          run_id: :string,
          base_url: :string,
          api_key_env: :string,
          profile_manifest: :string,
          scenario: :string,
          duration_seconds: :integer,
          concurrency: :integer,
          phase: :string,
          route_family: :string,
          model: :string,
          dry_run: :boolean,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    opts = Map.new(opts)

    cond do
      Map.get(opts, :help, false) ->
        {:help, @usage}

      invalid != [] ->
        {:error, "invalid options: #{format_invalid_options(invalid)}"}

      rest != [] ->
        {:error, "unexpected arguments: #{Enum.join(rest, " ")}"}

      true ->
        build_config(opts)
    end
  end

  defp strip_mix_separator(["--" | rest]), do: rest
  defp strip_mix_separator(args), do: args

  defp build_config(opts) do
    with {:ok, run_id} <- required_string(opts, :run_id, "--run-id"),
         {:ok, base_url} <- required_string(opts, :base_url, "--base-url"),
         {:ok, api_key_env} <- required_string(opts, :api_key_env, "--api-key-env"),
         {:ok, profile_manifest} <- required_string(opts, :profile_manifest, "--profile-manifest"),
         {:ok, scenario} <- required_string(opts, :scenario, "--scenario"),
         {:ok, scenario_config} <- scenario_config(scenario),
         {:ok, duration_seconds} <-
           positive_integer(opts, :duration_seconds, "--duration-seconds"),
         {:ok, concurrency} <- positive_integer(opts, :concurrency, "--concurrency"),
         {:ok, phase} <- required_string(opts, :phase, "--phase"),
         {:ok, route_family} <- route_family(Map.get(opts, :route_family, @default_route_family)),
         {:ok, base_url} <- validate_base_url(base_url) do
      {:ok,
       %{
         run_id: run_id,
         base_url: base_url,
         api_key_env: api_key_env,
         profile_manifest: profile_manifest,
         scenario: scenario,
         scenario_config: scenario_config,
         duration_seconds: duration_seconds,
         concurrency: concurrency,
         phase: phase,
         route_family: route_family,
         model: Map.get(opts, :model, @default_model),
         dry_run?: Map.get(opts, :dry_run, false),
         driver_dir: Path.join(["tmp", "gateway-perf", run_id, "driver"]),
         started_at: DateTime.utc_now(),
         manifest_profile_found?:
           manifest_contains_profile?(profile_manifest, scenario_config.profile)
       }}
    end
  end

  defp required_string(opts, key, label) do
    case Map.get(opts, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "#{label} is required"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, "#{label} is required"}
    end
  end

  defp positive_integer(opts, key, label) do
    case Map.get(opts, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, "#{label} must be a positive integer"}
    end
  end

  defp scenario_config(scenario) do
    case Map.fetch(@scenarios, scenario) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, "--scenario must be one of #{Enum.join(Map.keys(@scenarios), ", ")}"}
    end
  end

  defp route_family(value) when value in @route_families, do: {:ok, value}

  defp route_family(_value),
    do: {:error, "--route-family must be one of #{Enum.join(@route_families, ", ")}"}

  defp validate_base_url(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https", "ws", "wss"] and is_binary(uri.host) do
      {:ok, value}
    else
      {:error, "--base-url must be an http(s) or ws(s) URL"}
    end
  end

  defp manifest_contains_profile?(path, profile) do
    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, profiles} when is_list(profiles) <- Jason.decode(body) do
      Enum.any?(profiles, &match?(%{"name" => ^profile}, &1))
    else
      _other -> false
    end
  end

  defp print_dry_run(config) do
    summary = %{
      "dry_run" => true,
      "run_id" => config.run_id,
      "base_url" => config.base_url,
      "api_key_env" => config.api_key_env,
      "api_key_env_present" => System.get_env(config.api_key_env) not in [nil, ""],
      "profile_manifest" => config.profile_manifest,
      "manifest_profile_found" => config.manifest_profile_found?,
      "scenario" => config.scenario,
      "profile" => config.scenario_config.profile,
      "duration_seconds" => config.duration_seconds,
      "concurrency" => config.concurrency,
      "phase" => config.phase,
      "route_family" => config.route_family,
      "routes" => route_preview(config)
    }

    IO.puts(Jason.encode!(summary, pretty: true))
  end

  defp route_preview(config) do
    1..min(config.concurrency, 4)
    |> Enum.map(fn index ->
      route = route_for(config.route_family, index)
      %{"connection_index" => index, "route_family" => route, "path" => route_path(route)}
    end)
  end

  defp run_live(config) do
    api_key = fetch_api_key!(config.api_key_env)
    File.mkdir_p!(config.driver_dir)

    results =
      1..config.concurrency
      |> Task.async_stream(
        fn index -> run_connection(config, api_key, index) end,
        max_concurrency: config.concurrency,
        timeout: :timer.seconds(config.duration_seconds + 15),
        ordered: false
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> task_exit_result(reason)
      end)

    summary = write_summary!(config, results)

    IO.puts(
      "gateway-perf-ws wrote #{Path.join(config.driver_dir, "ws-summary.json")} status=#{summary["status"]} messages_received=#{summary["messages_received"]}"
    )

    if summary["status"] == "succeeded", do: :ok, else: System.halt(1)
  end

  defp fetch_api_key!(env_name) do
    case System.get_env(env_name) do
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "#{env_name} is not set"
    end
  end

  defp run_connection(config, api_key, index) do
    started_at = System.monotonic_time(:millisecond)
    route_family = route_for(config.route_family, index)
    connection_id = connection_id(index)
    events_path = Path.join(config.driver_dir, "#{connection_id}-events.jsonl")
    metadata_path = Path.join(config.driver_dir, "#{connection_id}-metadata.json")
    File.write!(events_path, "")

    state = %{
      config: config,
      api_key: api_key,
      route_family: route_family,
      connection_id: connection_id,
      started_at: started_at,
      deadline: started_at + :timer.seconds(config.duration_seconds),
      events_path: events_path,
      messages_received: 0,
      terminal_seen?: false,
      terminal_failure?: false,
      close_code: nil,
      close_reason_class: nil,
      error_code: nil,
      reconnect_attempts: 0
    }

    result =
      state
      |> connect_and_run()
      |> finalize_result()

    File.write!(metadata_path, Jason.encode_to_iodata!(result, pretty: true))
    result
  end

  defp connect_and_run(state) do
    uri =
      websocket_uri(
        state.config.base_url,
        state.route_family,
        state.config.scenario_config.profile
      )

    scheme = if uri.scheme == "wss", do: :https, else: :http
    websocket_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    port = uri.port || if uri.scheme == "wss", do: 443, else: 80

    record_event!(state, "connect_start", %{
      "route_family" => state.route_family,
      "path" => path_with_query(uri)
    })

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, port,
             protocols: [:http1],
             transport_opts: [timeout: 10_000]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(websocket_scheme, conn, path_with_query(uri), headers(state)),
         {:ok, conn, websocket} <- await_upgrade(conn, ref, state),
         {:ok, conn, websocket} <- send_payload(conn, websocket, ref, state) do
      receive_loop(conn, websocket, ref, state)
    else
      {:error, reason} -> Map.put(state, :error_code, classify_error(reason))
      {:error, _conn, reason, _responses} -> Map.put(state, :error_code, classify_error(reason))
    end
  end

  defp websocket_uri(base_url, route_family, profile) do
    base_url
    |> URI.parse()
    |> then(fn uri ->
      scheme = if uri.scheme in ["https", "wss"], do: "wss", else: "ws"

      query =
        uri.query
        |> merge_query(%{"profile" => profile})

      %{uri | scheme: scheme, path: route_path(route_family), query: query}
    end)
  end

  defp route_for("mixed", index), do: if(rem(index, 2) == 1, do: "backend", else: "v1")
  defp route_for(route_family, _index), do: route_family

  defp route_path("backend"), do: "/backend-api/codex/responses"
  defp route_path("v1"), do: "/v1/responses"

  defp merge_query(nil, added), do: URI.encode_query(added)
  defp merge_query("", added), do: URI.encode_query(added)

  defp merge_query(query, added) do
    query
    |> URI.decode_query()
    |> Map.merge(added)
    |> URI.encode_query()
  end

  defp path_with_query(%URI{path: path, query: nil}), do: path || "/"
  defp path_with_query(%URI{path: path, query: ""}), do: path || "/"
  defp path_with_query(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

  defp headers(state) do
    [
      {"authorization", "Bearer " <> state.api_key},
      {"openai-beta", "responses_websockets=2026-02-06"},
      {"x-request-id", state.connection_id},
      {"x-codex-turn-state", state.connection_id},
      {@correlation_header, state.config.scenario},
      {@profile_header, state.config.scenario_config.profile}
    ]
  end

  defp await_upgrade(conn, ref, state, status \\ nil, headers \\ nil) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status = websocket_status(responses, ref) || status
            headers = websocket_headers(responses, ref) || headers

            cond do
              Enum.any?(responses, &match?({:done, ^ref}, &1)) and status == 101 ->
                record_event!(state, "upgrade_ok", %{"status" => status})

                case Mint.WebSocket.new(conn, ref, status, headers) do
                  {:ok, conn, websocket} -> {:ok, conn, websocket}
                  {:error, _conn, reason} -> {:error, reason}
                end

              Enum.any?(responses, &match?({:done, ^ref}, &1)) ->
                {:error, {:upgrade_status, status || "unknown"}}

              true ->
                await_upgrade(conn, ref, state, status, headers)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref, state, status, headers)
        end
    after
      remaining_timeout_ms(state) -> {:error, :upgrade_timeout}
    end
  end

  defp websocket_status(responses, ref) do
    Enum.find_value(responses, fn
      {:status, ^ref, status} -> status
      _response -> nil
    end)
  end

  defp websocket_headers(responses, ref) do
    Enum.find_value(responses, fn
      {:headers, ^ref, headers} -> headers
      _response -> nil
    end)
  end

  defp send_payload(conn, websocket, ref, state) do
    payload = payload(state)
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, Jason.encode!(payload)})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    record_event!(state, "payload_sent", %{"route_family" => state.route_family})
    {:ok, conn, websocket}
  end

  defp payload(%{route_family: "v1"} = state) do
    %{
      "type" => "response.create",
      "model" => state.config.model,
      "store" => false,
      "input" => "synthetic gateway websocket performance request"
    }
  end

  defp payload(state) do
    %{
      "model" => state.config.model,
      "stream" => true,
      "input" => "synthetic gateway websocket performance request"
    }
  end

  defp receive_loop(conn, websocket, ref, state) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case decode_responses(websocket, ref, responses, state) do
              {:ok, websocket, state} -> maybe_continue_receive(conn, websocket, ref, state)
              {:stop, websocket, state} -> close_connection(conn, websocket, ref, state)
            end

          {:error, conn, reason, responses} ->
            state = handle_transport_error(websocket, ref, responses, state, reason)
            Mint.HTTP.close(conn)
            state

          :unknown ->
            receive_loop(conn, websocket, ref, state)
        end
    after
      remaining_timeout_ms(state) ->
        record_event!(state, "duration_elapsed", %{})

        close_connection(
          conn,
          websocket,
          ref,
          Map.put(state, :close_reason_class, "duration_elapsed")
        )
    end
  end

  defp maybe_continue_receive(conn, websocket, ref, %{terminal_seen?: true} = state) do
    close_connection(conn, websocket, ref, state)
  end

  defp maybe_continue_receive(conn, websocket, ref, state),
    do: receive_loop(conn, websocket, ref, state)

  defp decode_responses(websocket, ref, responses, state) do
    Enum.reduce_while(responses, {:ok, websocket, state}, fn
      {:data, ^ref, data}, {:ok, websocket, state} ->
        case Mint.WebSocket.decode(websocket, data) do
          {:ok, websocket, frames} ->
            case handle_frames(websocket, frames, state) do
              {:ok, websocket, state} -> {:cont, {:ok, websocket, state}}
              {:stop, websocket, state} -> {:halt, {:stop, websocket, state}}
            end

          {:error, websocket, reason} ->
            state =
              state
              |> Map.put(:error_code, classify_error(reason))
              |> Map.put(:terminal_failure?, true)

            {:halt, {:stop, websocket, state}}
        end

      {:error, ^ref, reason}, {:ok, websocket, state} ->
        state =
          state
          |> Map.put(:error_code, classify_error(reason))
          |> Map.put(:terminal_failure?, true)

        {:halt, {:stop, websocket, state}}

      _response, acc ->
        {:cont, acc}
    end)
  end

  defp handle_frames(websocket, frames, state) do
    Enum.reduce_while(frames, {:ok, websocket, state}, fn
      {:text, text}, {:ok, websocket, state} ->
        state = record_text_message(state, text)

        if state.terminal_seen? or state.terminal_failure? do
          {:halt, {:stop, websocket, state}}
        else
          {:cont, {:ok, websocket, state}}
        end

      {:close, code, reason}, {:ok, websocket, state} ->
        state =
          state
          |> Map.put(:close_code, code)
          |> Map.put(:close_reason_class, close_reason_class(code, reason))

        record_event!(state, "close_frame", %{
          "close_code" => code,
          "close_reason_class" => state.close_reason_class
        })

        {:halt, {:stop, websocket, state}}

      _frame, acc ->
        {:cont, acc}
    end)
  end

  defp record_text_message(state, text) do
    metadata = decode_event_metadata(text)
    state = %{state | messages_received: state.messages_received + 1}
    record_event!(state, "message", metadata)

    cond do
      terminal_success?(metadata) ->
        %{state | terminal_seen?: true}

      terminal_failure?(metadata) ->
        %{state | terminal_failure?: true, error_code: Map.get(metadata, "error_code")}

      true ->
        state
    end
  end

  defp decode_event_metadata(text) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) ->
        %{
          "event_type" => decoded["type"],
          "status" => decoded["status"] || get_in(decoded, ["response", "status"]),
          "profile" => decoded["profile"],
          "error_code" => get_in(decoded, ["error", "code"]),
          "response_status" => get_in(decoded, ["response", "status"]),
          "bytes" => byte_size(text)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _decode_error ->
        %{"event_type" => "non_json_text", "bytes" => byte_size(text)}
    end
  end

  defp terminal_success?(%{"event_type" => type})
       when type in ["response.completed", "response.done"], do: true

  defp terminal_success?(%{"status" => "completed"}), do: true
  defp terminal_success?(_metadata), do: false

  defp terminal_failure?(%{"event_type" => type})
       when type in ["error", "response.failed", "response.incomplete"], do: true

  defp terminal_failure?(%{"response_status" => status}) when status in ["failed", "incomplete"],
    do: true

  defp terminal_failure?(_metadata), do: false

  defp handle_transport_error(websocket, ref, responses, state, reason) do
    state =
      case decode_responses(websocket, ref, responses, state) do
        {:ok, _websocket, state} -> state
        {:stop, _websocket, state} -> state
      end

    record_event!(state, "transport_error", %{"error_code" => classify_error(reason)})
    Map.put(state, :error_code, classify_error(reason))
  end

  defp close_connection(conn, websocket, ref, state) do
    {:ok, _websocket, data} = Mint.WebSocket.encode(websocket, :close)
    _result = Mint.WebSocket.stream_request_body(conn, ref, data)
    Mint.HTTP.close(conn)
    state
  catch
    :exit, _reason -> state
  end

  defp finalize_result(state) do
    duration_ms = System.monotonic_time(:millisecond) - state.started_at
    outcome = outcome(state)
    expected? = MapSet.member?(state.config.scenario_config.expected, outcome)

    successful? =
      expected? and state.messages_received > 0 and close_semantics_classified?(outcome)

    result = %{
      connection_id: state.connection_id,
      route_family: state.route_family,
      scenario: state.config.scenario,
      profile: state.config.scenario_config.profile,
      phase: state.config.phase,
      outcome: outcome,
      status: if(successful?, do: "succeeded", else: "failed"),
      messages_received: state.messages_received,
      clean_close?: outcome == "completed",
      classified_disconnect?: outcome == "classified_disconnect",
      reconnect_attempts: state.reconnect_attempts,
      duration_ms: max(duration_ms, 0)
    }

    result
    |> maybe_put(:error_code, state.error_code)
    |> maybe_put(:close_code, state.close_code)
    |> maybe_put(:close_reason_class, state.close_reason_class)
  end

  defp outcome(%{terminal_seen?: true}), do: "completed"
  defp outcome(%{terminal_failure?: true}), do: "classified_failure"

  defp outcome(%{close_code: code}) when is_integer(code) and code not in [1000, 1005],
    do: "classified_disconnect"

  defp outcome(%{close_reason_class: "duration_elapsed", messages_received: count})
       when count > 0, do: "duration_elapsed"

  defp outcome(%{error_code: code}) when is_binary(code), do: "classified_disconnect"
  defp outcome(%{messages_received: 0}), do: "no_message_timeout"
  defp outcome(_state), do: "classified_disconnect"

  defp close_semantics_classified?(outcome),
    do: outcome in ~w(completed classified_failure classified_disconnect duration_elapsed)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp write_summary!(config, results) do
    finished_at = DateTime.utc_now()
    succeeded = Enum.count(results, &(&1.status == "succeeded"))
    failed = Enum.count(results, &(&1.status == "failed"))

    summary = %{
      "run_id" => config.run_id,
      "phase" => config.phase,
      "scenario" => config.scenario,
      "profile" => config.scenario_config.profile,
      "route_family" => config.route_family,
      "base_url" => config.base_url,
      "profile_manifest" => config.profile_manifest,
      "manifest_profile_found" => config.manifest_profile_found?,
      "duration_seconds" => config.duration_seconds,
      "concurrency" => config.concurrency,
      "started_at" => DateTime.to_iso8601(config.started_at),
      "finished_at" => DateTime.to_iso8601(finished_at),
      "elapsed_ms" => DateTime.diff(finished_at, config.started_at, :millisecond),
      "status" => if(failed == 0, do: "succeeded", else: "failed"),
      "requests_started" => length(results),
      "requests_completed" => succeeded,
      "requests_succeeded" => succeeded,
      "requests_failed" => failed,
      "status_counts" => counts_by(results, & &1.status),
      "outcome_counts" => counts_by(results, & &1.outcome),
      "error_counts" => counts_by(results, &Map.get(&1, :error_code, "none")),
      "messages_received" => Enum.sum(Enum.map(results, & &1.messages_received)),
      "clean_closes" => Enum.count(results, & &1.clean_close?),
      "classified_disconnects" => Enum.count(results, & &1.classified_disconnect?),
      "reconnect_attempts" => Enum.sum(Enum.map(results, & &1.reconnect_attempts)),
      "connections" => Enum.sort_by(results, & &1.connection_id)
    }

    File.write!(
      Path.join(config.driver_dir, "ws-summary.json"),
      Jason.encode_to_iodata!(summary, pretty: true)
    )

    summary
  end

  defp counts_by(rows, fun) do
    rows
    |> Enum.map(fun)
    |> Enum.frequencies()
  end

  defp task_exit_result(reason) do
    %{
      connection_id: "task-exit-#{System.unique_integer([:positive])}",
      route_family: "unknown",
      outcome: "task_exit",
      status: "failed",
      messages_received: 0,
      clean_close?: false,
      classified_disconnect?: true,
      reconnect_attempts: 0,
      duration_ms: 0,
      error_code: classify_error(reason)
    }
  end

  defp record_event!(state, kind, metadata) do
    event =
      metadata
      |> Map.merge(%{
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "kind" => kind,
        "connection_id" => state.connection_id,
        "route_family" => state.route_family,
        "scenario" => state.config.scenario,
        "profile" => state.config.scenario_config.profile,
        "phase" => state.config.phase
      })

    File.write!(state.events_path, [Jason.encode_to_iodata!(event), "\n"], [:append])
  end

  defp close_reason_class(1000, _reason), do: "normal"
  defp close_reason_class(1001, _reason), do: "going_away"
  defp close_reason_class(1006, _reason), do: "abnormal"
  defp close_reason_class(code, _reason) when is_integer(code), do: "websocket_close_#{code}"
  defp close_reason_class(_code, _reason), do: "websocket_close_unknown"

  defp classify_error({:upgrade_status, status}), do: "upgrade_status_#{status}"
  defp classify_error(%Mint.TransportError{reason: reason}), do: "transport_#{safe_atom(reason)}"
  defp classify_error(%Mint.HTTPError{reason: reason}), do: "http_#{safe_atom(reason)}"
  defp classify_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_error(reason) when is_binary(reason), do: reason
  defp classify_error(reason), do: reason |> inspect() |> String.slice(0, 80)

  defp safe_atom(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_atom(reason), do: reason |> inspect() |> String.slice(0, 40)

  defp remaining_timeout_ms(state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)
    max(remaining, 0)
  end

  defp connection_id(index),
    do: "ws-" <> (index |> Integer.to_string() |> String.pad_leading(4, "0"))

  defp format_invalid_options(invalid) do
    invalid
    |> Enum.map(fn {option, value} -> "#{option}=#{inspect(value)}" end)
    |> Enum.join(", ")
  end
end

CodexPooler.Dev.GatewayPerfWebsocketDriver.run(System.argv())
