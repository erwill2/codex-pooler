defmodule CodexPoolerWeb.V1.AudioController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Audio
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Service
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.V1.PublicGatewayDispatch

  def transcriptions(conn, params) do
    PublicGatewayDispatch.authenticated(
      conn,
      RouteClass.audio_transcription(),
      "/v1/audio/transcriptions",
      fn auth ->
        with {:ok, _validated} <- Audio.validate_transcription(params) do
          opts =
            conn
            |> GatewayHelpers.request_opts()
            |> Map.put(:upstream_endpoint, "/backend-api/transcribe")
            |> Map.put(:forced_transcription_model, Service.backend_transcription_model())
            |> RequestOptions.from_conn_metadata("/backend-api/transcribe", params)

          Service.execute_multipart(auth, "/backend-api/transcribe", params, opts)
        end
      end
    )
  end
end
