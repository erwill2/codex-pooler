defmodule CodexPooler.Access.APIKeys.TouchDebounce do
  @moduledoc """
  Debounces successful API key authentication touch writes per node.

  Each node keeps only the most recent observed touch timestamp per API key and
  flushes at most once per 60-second interval. Multiple replicas may flush the
  same key concurrently, so the database write is idempotent and monotonic: it
  only advances `last_used_at` when the stored value is nil or older than the
  flushed timestamp. Authentication status, expiry, pool visibility, and policy
  checks happen before this best-effort touch path and do not depend on the
  debounce process.
  """

  use GenServer

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Repo

  @debounce_interval_ms 60_000

  @type state :: %{
          pending: %{optional(Ecto.UUID.t()) => DateTime.t()},
          timer_ref: reference() | nil,
          debounce_interval_ms: pos_integer()
        }

  @spec debounce_interval_ms() :: pos_integer()
  def debounce_interval_ms, do: @debounce_interval_ms

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec touch(APIKey.t(), DateTime.t()) :: APIKey.t()
  def touch(%APIKey{} = api_key, %DateTime{} = touched_at \\ now()) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:touch, api_key.id, touched_at})
    end

    %{api_key | last_used_at: newest(api_key.last_used_at, touched_at)}
  end

  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush, :infinity)
  end

  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset, :infinity)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      pending: %{},
      timer_ref: nil,
      debounce_interval_ms: Keyword.get(opts, :debounce_interval_ms, @debounce_interval_ms)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:touch, api_key_id, %DateTime{} = touched_at}, state)
      when is_binary(api_key_id) do
    pending = Map.update(state.pending, api_key_id, touched_at, &newest(&1, touched_at))

    {:noreply, %{state | pending: pending} |> ensure_timer()}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    state = cancel_timer(state)
    flush_pending(state.pending)
    {:reply, :ok, %{state | pending: %{}, timer_ref: nil}}
  end

  def handle_call(:reset, _from, state) do
    state = cancel_timer(state)
    {:reply, :ok, %{state | pending: %{}, timer_ref: nil}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    flush_pending(state.pending)
    {:noreply, %{state | pending: %{}, timer_ref: nil}}
  end

  defp ensure_timer(%{timer_ref: nil} = state) do
    timer_ref = Process.send_after(self(), :flush, state.debounce_interval_ms)
    %{state | timer_ref: timer_ref}
  end

  defp ensure_timer(state), do: state

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
  end

  defp flush_pending(pending) do
    Enum.each(pending, fn {api_key_id, touched_at} ->
      APIKey
      |> where([key], key.id == ^api_key_id)
      |> where([key], is_nil(key.last_used_at) or key.last_used_at < ^touched_at)
      |> Repo.update_all(set: [last_used_at: touched_at])
    end)
  end

  defp newest(nil, %DateTime{} = right), do: right

  defp newest(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
