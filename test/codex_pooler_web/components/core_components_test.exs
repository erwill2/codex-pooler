defmodule CodexPoolerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents

  test "input renders aria-invalid and aria-describedby when errors exist" do
    html =
      render_component(&input/1, %{
        id: "user_email",
        name: "email",
        type: "text",
        errors: ["is invalid"]
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "input#user_email[aria-invalid='true']") != []
    assert LazyHTML.query(fragment, "input#user_email[aria-describedby='user_email-error']") != []
    assert LazyHTML.query(fragment, "#user_email-error") != []
    assert html =~ "is invalid"
  end

  test "input omits error container when no errors exist" do
    html =
      render_component(&input/1, %{
        id: "user_email",
        name: "email",
        type: "text",
        errors: []
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "input#user_email[aria-invalid='false']") != []
    assert LazyHTML.query(fragment, "#user_email-error") |> Enum.empty?()
  end

  test "input safely handles nil or empty id without generating invalid -error IDs" do
    html =
      render_component(&input/1, %{
        id: nil,
        name: "email",
        type: "text",
        errors: ["is invalid"]
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "input[aria-invalid='true']") != []
    assert LazyHTML.query(fragment, "input[aria-describedby='-error']") |> Enum.empty?()
    assert LazyHTML.query(fragment, "#-error") |> Enum.empty?()
  end

  test "select input renders aria-invalid and aria-describedby when errors exist" do
    html =
      render_component(&input/1, %{
        id: "user_role",
        name: "role",
        type: "select",
        options: ["Admin": "admin", "User": "user"],
        errors: ["must be selected"]
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "select#user_role[aria-invalid='true']") != []
    assert LazyHTML.query(fragment, "select#user_role[aria-describedby='user_role-error']") != []
    assert LazyHTML.query(fragment, "#user_role-error") != []
  end

  test "textarea input renders aria-invalid and aria-describedby when errors exist" do
    html =
      render_component(&input/1, %{
        id: "user_bio",
        name: "bio",
        type: "textarea",
        errors: ["is too short"]
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "textarea#user_bio[aria-invalid='true']") != []
    assert LazyHTML.query(fragment, "textarea#user_bio[aria-describedby='user_bio-error']") != []
    assert LazyHTML.query(fragment, "#user_bio-error") != []
  end

  test "checkbox input renders aria-invalid and aria-describedby when errors exist" do
    html =
      render_component(&input/1, %{
        id: "user_terms",
        name: "terms",
        type: "checkbox",
        label: "Accept terms",
        errors: ["must be accepted"]
      })

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.query(fragment, "input#user_terms[aria-invalid='true']") != []
    assert LazyHTML.query(fragment, "input#user_terms[aria-describedby='user_terms-error']") != []
    assert LazyHTML.query(fragment, "#user_terms-error") != []
  end
end
