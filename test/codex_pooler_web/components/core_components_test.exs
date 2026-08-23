defmodule CodexPoolerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents

  test "input component renders aria-invalid when errors are present" do
    html_no_error =
      render_component(&input/1, id: "test-input", name: "user[email]", value: "test@example.com", errors: [])

    refute html_no_error =~ "aria-invalid"

    html_with_error =
      render_component(&input/1, id: "test-input", name: "user[email]", value: "", errors: ["is invalid"])

    assert html_with_error =~ ~s(aria-invalid="true")
  end

  test "select component renders aria-invalid when errors are present" do
    html_no_error =
      render_component(&input/1, type: "select", id: "test-select", name: "user[role]", value: nil, options: ["Admin": "admin"], errors: [])

    refute html_no_error =~ "aria-invalid"

    html_with_error =
      render_component(&input/1, type: "select", id: "test-select", name: "user[role]", value: nil, options: ["Admin": "admin"], errors: ["must be selected"])

    assert html_with_error =~ ~s(aria-invalid="true")
  end

  test "textarea component renders aria-invalid when errors are present" do
    html_no_error =
      render_component(&input/1, type: "textarea", id: "test-textarea", name: "user[bio]", value: "", errors: [])

    refute html_no_error =~ "aria-invalid"

    html_with_error =
      render_component(&input/1, type: "textarea", id: "test-textarea", name: "user[bio]", value: "", errors: ["can't be blank"])

    assert html_with_error =~ ~s(aria-invalid="true")
  end

  test "otp_input component renders aria-invalid on hidden value input when errors are present" do
    html_no_error =
      render_component(&otp_input/1, id: "test-otp", name: "code", value: "", errors: [])

    refute html_no_error =~ "aria-invalid"

    html_with_error =
      render_component(&otp_input/1, id: "test-otp", name: "code", value: "", errors: ["is invalid"])

    assert html_with_error =~ ~s(aria-invalid="true")
  end
end
