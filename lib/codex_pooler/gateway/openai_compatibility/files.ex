defmodule CodexPooler.Gateway.OpenAICompatibility.Files do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Validation}

  @supported_purposes ~w(user_data assistants vision batch fine-tune)

  @spec validate_create(term()) ::
          {:ok, %{purpose: String.t(), file: map()}} | {:error, Error.reason()}
  def validate_create(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :files),
         {:ok, purpose} <- purpose(payload),
         {:ok, file} <- file_metadata(payload) do
      {:ok, %{purpose: purpose, file: file}}
    end
  end

  defp purpose(%{"purpose" => purpose}) when purpose in @supported_purposes, do: {:ok, purpose}

  defp purpose(%{"purpose" => _purpose}),
    do: {:error, Error.invalid_request("file purpose is not supported", "purpose")}

  defp purpose(_payload), do: {:error, Error.invalid_request("purpose is required", "purpose")}

  defp file_metadata(%{"file" => file}), do: Validation.upload_metadata(file)
  defp file_metadata(_payload), do: {:error, Error.invalid_request("file is required", "file")}
end
