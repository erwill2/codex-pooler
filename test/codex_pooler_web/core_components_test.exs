defmodule CodexPoolerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents

  describe "input/1 accessibility and error attributes" do
    test "renders input without errors, omitting aria-invalid and error container" do
      assigns = %{id: "user_email", name: "user[email]", value: "test@example.com", errors: []}

      html =
        rendered_to_string(~H"""
        <.input id={@id} name={@name} value={@value} errors={@errors} label="Email" />
        """)

      assert html =~ ~s(id="user_email")
      refute html =~ "aria-invalid"
      refute html =~ "aria-describedby"
      refute html =~ ~s(id="user_email-error")
    end

    test "renders input with errors, linking aria-describedby to single error container div" do
      assigns = %{
        id: "user_email",
        name: "user[email]",
        value: "",
        errors: ["can't be blank", "is invalid"]
      }

      html =
        rendered_to_string(~H"""
        <.input id={@id} name={@name} value={@value} errors={@errors} label="Email" />
        """)

      assert html =~ "aria-invalid"
      assert html =~ ~s(aria-describedby="user_email-error")
      assert html =~ ~s(<div id="user_email-error">)
      assert html =~ "can&#39;t be blank"
      assert html =~ "is invalid"
    end

    test "renders select with errors, linking aria-describedby to error container" do
      assigns = %{
        id: "user_role",
        name: "user[role]",
        value: "",
        errors: ["must select a role"],
        options: [Admin: "admin"]
      }

      html =
        rendered_to_string(~H"""
        <.input
          type="select"
          id={@id}
          name={@name}
          value={@value}
          errors={@errors}
          options={@options}
          label="Role"
        />
        """)

      assert html =~ "aria-invalid"
      assert html =~ ~s(aria-describedby="user_role-error")
      assert html =~ ~s(<div id="user_role-error">)
      assert html =~ "must select a role"
    end

    test "renders textarea with errors, linking aria-describedby to error container" do
      assigns = %{id: "user_bio", name: "user[bio]", value: "", errors: ["too short"]}

      html =
        rendered_to_string(~H"""
        <.input type="textarea" id={@id} name={@name} value={@value} errors={@errors} label="Bio" />
        """)

      assert html =~ "aria-invalid"
      assert html =~ ~s(aria-describedby="user_bio-error")
      assert html =~ ~s(<div id="user_bio-error">)
      assert html =~ "too short"
    end

    test "renders checkbox with errors, linking aria-describedby to error container" do
      assigns = %{id: "terms", name: "user[terms]", value: "false", errors: ["must be accepted"]}

      html =
        rendered_to_string(~H"""
        <.input
          type="checkbox"
          id={@id}
          name={@name}
          value={@value}
          errors={@errors}
          label="Accept Terms"
        />
        """)

      assert html =~ "aria-invalid"
      assert html =~ ~s(aria-describedby="terms-error")
      assert html =~ ~s(<div id="terms-error">)
      assert html =~ "must be accepted"
    end
  end
end
