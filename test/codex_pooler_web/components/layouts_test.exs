defmodule CodexPoolerWeb.LayoutsTest do
  use CodexPoolerWeb.ConnCase, async: true
  use Phoenix.Component
  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Layouts

  test "theme_toggle renders buttons with type and aria-label" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Layouts.theme_toggle id="theme-toggle" />
      """)

    assert html =~ ~s(type="button")
    assert html =~ ~s(aria-label="System theme")
    assert html =~ ~s(aria-label="Light theme")
    assert html =~ ~s(aria-label="Dark theme")
  end
end
