defmodule CodexPoolerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents

  test "renders text input without errors" do
    assigns = %{id: "user_name", name: "user[name]", value: "Alice"}

    html =
      rendered_to_string(~H"""
      <.input id={@id} name={@name} value={@value} label="Name" />
      """)

    assert html =~ ~s(id="user_name")
    assert html =~ ~s(name="user[name]")
    assert html =~ ~s(value="Alice")
    refute html =~ "aria-invalid"
    refute html =~ "aria-describedby"
    refute html =~ "user_name-error"
  end

  test "renders text input with errors and proper ARIA accessibility attributes" do
    assigns = %{id: "user_email", name: "user[email]", value: "", errors: ["can't be blank", "is invalid"]}

    html =
      rendered_to_string(~H"""
      <.input id={@id} name={@name} value={@value} label="Email" errors={@errors} />
      """)

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="user_email-error")
    assert html =~ ~s(<div id="user_email-error">)
    assert html =~ "can&#39;t be blank"
    assert html =~ "is invalid"
  end

  test "renders select input with errors and proper ARIA accessibility attributes" do
    assigns = %{id: "user_role", name: "user[role]", value: "", errors: ["must be selected"], options: [Admin: "admin", User: "user"]}

    html =
      rendered_to_string(~H"""
      <.input type="select" id={@id} name={@name} value={@value} label="Role" errors={@errors} options={@options} />
      """)

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="user_role-error")
    assert html =~ ~s(<div id="user_role-error">)
    assert html =~ "must be selected"
  end

  test "renders textarea input with errors and proper ARIA accessibility attributes" do
    assigns = %{id: "user_bio", name: "user[bio]", value: "", errors: ["is too short"]}

    html =
      rendered_to_string(~H"""
      <.input type="textarea" id={@id} name={@name} value={@value} label="Bio" errors={@errors} />
      """)

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="user_bio-error")
    assert html =~ ~s(<div id="user_bio-error">)
    assert html =~ "is too short"
  end

  test "renders checkbox input with errors and proper ARIA accessibility attributes" do
    assigns = %{id: "user_terms", name: "user[terms]", value: "false", errors: ["must be accepted"]}

    html =
      rendered_to_string(~H"""
      <.input type="checkbox" id={@id} name={@name} value={@value} label="Accept terms" errors={@errors} />
      """)

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="user_terms-error")
    assert html =~ ~s(<div id="user_terms-error">)
    assert html =~ "must be accepted"
  end
end
