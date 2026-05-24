defmodule CodexPooler.Gateway.Transports.FileBridgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.FileBridge

  test "logs upload transport failures with safe request context" do
    request_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    path = upload_tempfile!("sample upload")

    request_options =
      %{request_id: request_id}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(
        operation: :upload,
        endpoint: "/v1/files/upload",
        pool_upstream_assignment_id: assignment_id,
        upstream_identity_id: identity_id,
        route_metadata: %{"route_class" => "file_upload", "routing_strategy" => "test_strategy"}
      )

    log =
      capture_log(fn ->
        assert {:error, %{code: "upstream_file_upload_failed"}} =
                 FileBridge.upload_file(
                   "http://127.0.0.1:1/upload",
                   %{"path" => path, "content_type" => "text/plain"},
                   request_options
                 )
      end)

    assert log =~ "file bridge transport failed"
    assert log =~ "operation=upload"
    assert log =~ "endpoint=/v1/files/upload"
    assert log =~ "request_id=#{request_id}"
    assert log =~ "pool_upstream_assignment_id=#{assignment_id}"
    assert log =~ "upstream_identity_id=#{identity_id}"
    assert log =~ "route_class=file_upload"
    assert log =~ "routing_strategy=test_strategy"
    assert log =~ "exception="
    assert log =~ "reason="
    refute log =~ "sample upload"
  end

  defp upload_tempfile!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-upload-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, contents)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end
end
