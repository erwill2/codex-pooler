defmodule CodexPoolerWeb.ErrorHTML do
  @moduledoc """
  HTML error renderer for browser requests.
  """
  use CodexPoolerWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
