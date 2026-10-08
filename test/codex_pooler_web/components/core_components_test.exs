defmodule CodexPoolerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias CodexPoolerWeb.CoreComponents

  test "input component renders aria-invalid, aria-describedby, and error container when errors present" do
    assigns = %{
      errors: ["is invalid", "must be unique"]
    }

    html =
      render_component(&CoreComponents.input/1,
        id: "username-input",
        name: "user[username]",
        value: "test",
        label: "Username",
        errors: assigns.errors
      )

    assert html =~ ~s(id="username-input")
    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="username-input-error")
    assert html =~ ~s(id="username-input-error")
    assert html =~ "is invalid"
    assert html =~ "must be unique"
  end

  test "input component does not render aria-invalid or aria-describedby when errors are empty" do
    html =
      render_component(&CoreComponents.input/1,
        id: "username-input",
        name: "user[username]",
        value: "test",
        label: "Username",
        errors: []
      )

    refute html =~ ~s(aria-invalid=)
    refute html =~ ~s(aria-describedby="username-input-error")
    refute html =~ ~s(id="username-input-error")
  end
end
