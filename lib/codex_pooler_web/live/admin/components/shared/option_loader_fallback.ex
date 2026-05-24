defmodule CodexPoolerWeb.Admin.OptionLoaderFallback do
  @moduledoc """
  Shared fallback handling for admin option loaders.
  """

  require Logger

  @spec empty_options(atom(), atom(), term(), map(), [atom()]) :: {[], [map()]}
  def empty_options(admin_surface, loader, reason, warning, allowed_not_found_codes) do
    if not_found_error?(reason, allowed_not_found_codes) do
      {[], []}
    else
      Logger.warning("admin option loader unavailable",
        admin_surface: admin_surface,
        loader: loader,
        error_code: error_code(reason)
      )

      {[], [Map.put(warning, :id, loader)]}
    end
  end

  defp not_found_error?(%{code: code}, allowed_codes), do: code in allowed_codes
  defp not_found_error?(_reason, _allowed_codes), do: false

  defp error_code(%{code: code}), do: code
  defp error_code(_reason), do: :unknown
end
