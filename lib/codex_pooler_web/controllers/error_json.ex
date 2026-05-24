defmodule CodexPoolerWeb.ErrorJSON do
  @moduledoc """
  JSON error renderer for API requests.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
