defmodule CodexPooler.Dev do
  @moduledoc """
  Production-safe boundary for local development support modules.

  Dev support code is compiled from `dev_support/` only in dev and test. Runtime
  modules should call this boundary instead of referencing local helpers directly.
  """

  @seeds_module CodexPooler.Dev.Seeds
  @gateway_perf_probe_module CodexPooler.Dev.GatewayPerfProbe

  @type dev_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec support_available?() :: boolean()
  def support_available?, do: Code.ensure_loaded?(@seeds_module)

  @spec seed_full() :: {:ok, map()} | {:error, dev_error()}
  def seed_full do
    with {:ok, seeds_module} <- loaded_module(@seeds_module) do
      {:ok, seeds_module.full()}
    end
  rescue
    error in RuntimeError -> {:error, unavailable_error(Exception.message(error))}
  end

  @spec gateway_perf_probe_child() :: module() | nil
  def gateway_perf_probe_child do
    with {:ok, probe_module} <- loaded_module(@gateway_perf_probe_module),
         true <- probe_module.enabled?() do
      probe_module
    else
      _unavailable -> nil
    end
  end

  defp loaded_module(module) do
    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, unavailable_error("Development support is not compiled for this environment")}
    end
  end

  defp unavailable_error(message), do: %{code: :dev_support_unavailable, message: message}
end
