defmodule CodexPoolerWeb.CoreComponentsTest do
  use CodexPoolerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents

  test "input renders standard state without invalid or describedby attributes" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.input id="user_email" name="user[email]" value="test@example.com" label="Email" />
      """)

    refute html =~ "aria-invalid"
    refute html =~ "aria-describedby"
    refute html =~ "user_email-error"
  end

  test "input with errors renders aria-invalid, aria-describedby, and wrapped error container" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.input id="user_email" name="user[email]" value="" errors={["can't be blank"]} label="Email" />
      """)

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="user_email-error")
    assert html =~ ~s(id="user_email-error")
    assert html =~ "can&#39;t be blank"
  end

  test "select and textarea inputs associate errors with a single container" do
    assigns = %{}

    select_html =
      rendered_to_string(~H"""
      <.input
        type="select"
        id="user_role"
        name="user[role]"
        options={[Admin: "admin", User: "user"]}
        errors={["is invalid"]}
      />
      """)

    assert select_html =~ ~s(aria-invalid="true")
    assert select_html =~ ~s(aria-describedby="user_role-error")
    assert select_html =~ ~s(id="user_role-error")

    textarea_html =
      rendered_to_string(~H"""
      <.input
        type="textarea"
        id="user_bio"
        name="user[bio]"
        errors={["is too short"]}
      />
      """)

    assert textarea_html =~ ~s(aria-invalid="true")
    assert textarea_html =~ ~s(aria-describedby="user_bio-error")
    assert textarea_html =~ ~s(id="user_bio-error")
  end
end
