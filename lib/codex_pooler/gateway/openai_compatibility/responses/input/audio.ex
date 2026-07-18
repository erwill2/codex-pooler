defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.Audio do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @canonical_mimes %{
    "wav" => "audio/wav",
    "mp3" => "audio/mpeg",
    "m4a" => "audio/mp4",
    "webm" => "audio/webm",
    "ogg" => "audio/ogg"
  }

  @decoded_max_bytes 52_428_800
  @encoded_non_whitespace_max_bytes 69_905_068
  @encoded_count_chunk_bytes 65_536
  @ascii_whitespace [" ", "\t", "\r", "\n"]

  @type public_format :: String.t()
  @type public_audio :: %{required(String.t()) => binary()}
  @type public_part :: %{required(String.t()) => binary() | public_audio()}
  @type canonical_part :: %{required(String.t()) => binary()}
  @type result :: {:ok, canonical_part()} | {:error, Error.reason()}

  @spec supported_format?(term()) :: boolean()
  def supported_format?(format) when is_binary(format), do: Map.has_key?(@canonical_mimes, format)
  def supported_format?(_format), do: false

  @spec normalize_part(public_part()) :: result()
  def normalize_part(%{
        "type" => "input_audio",
        "input_audio" => %{"data" => data, "format" => format}
      }) do
    with :ok <- precheck_encoded_size(data),
         {:ok, decoded} <- decode_audio(data) do
      mime = Map.fetch!(@canonical_mimes, format)

      {:ok,
       %{
         "type" => "input_audio",
         "audio_url" => "data:" <> mime <> ";base64," <> Base.encode64(decoded)
       }}
    end
  end

  @spec precheck_encoded_size(binary()) :: :ok | {:error, Error.reason()}
  defp precheck_encoded_size(data) do
    if encoded_size_exceeded?(data), do: {:error, oversized_error()}, else: :ok
  end

  @spec encoded_size_exceeded?(binary()) :: boolean()
  defp encoded_size_exceeded?(data)
       when byte_size(data) <= @encoded_non_whitespace_max_bytes,
       do: false

  defp encoded_size_exceeded?(data) do
    pattern = :binary.compile_pattern(@ascii_whitespace)
    count_non_whitespace(data, pattern, 0, 0)
  end

  @spec count_non_whitespace(binary(), :binary.cp(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  defp count_non_whitespace(data, _pattern, offset, _count) when offset == byte_size(data),
    do: false

  defp count_non_whitespace(data, pattern, offset, count) do
    chunk_size = min(@encoded_count_chunk_bytes, byte_size(data) - offset)
    chunk = binary_part(data, offset, chunk_size)
    next_count = count + chunk_size - length(:binary.matches(chunk, pattern))

    if next_count > @encoded_non_whitespace_max_bytes do
      true
    else
      count_non_whitespace(data, pattern, offset + chunk_size, next_count)
    end
  end

  @spec decode_audio(binary()) :: {:ok, binary()} | {:error, Error.reason()}
  defp decode_audio(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, <<>>} -> {:error, invalid_base64_error()}
      {:ok, decoded} when byte_size(decoded) > @decoded_max_bytes -> {:error, oversized_error()}
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, invalid_base64_error()}
    end
  end

  @spec invalid_base64_error() :: Error.reason()
  defp invalid_base64_error,
    do: Error.invalid_request("input_audio data must be base64", "input")

  @spec oversized_error() :: Error.reason()
  defp oversized_error,
    do: Error.invalid_request("input_audio data must be 50 MiB or smaller", "input")
end
