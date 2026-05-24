defmodule CodexPooler.Gateway.OpenAICompatibility.Audio do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Validation}

  @supported_models ~w(gpt-4o-transcribe)

  @spec validate_transcription(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate_transcription(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :audio),
         :ok <- validate_model(payload),
         {:ok, file} <- file_metadata(payload) do
      {:ok, Map.put(payload, "file", file)}
    end
  end

  defp validate_model(%{"model" => model}) when model in @supported_models, do: :ok

  defp validate_model(%{"model" => _model}),
    do: {:error, Error.invalid_model("audio transcription model is not supported")}

  defp validate_model(_payload), do: {:error, Error.invalid_request("model is required", "model")}

  defp file_metadata(%{"file" => file}), do: Validation.upload_metadata(file)
  defp file_metadata(_payload), do: {:error, Error.invalid_request("file is required", "file")}
end
