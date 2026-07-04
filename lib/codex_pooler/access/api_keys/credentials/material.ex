defmodule CodexPooler.Access.APIKeys.Material do
  @moduledoc false

  @api_key_prefix_scheme "sk-cxp"
  @api_key_public_bytes 6
  @api_key_secret_bytes 32

  @spec generate() :: {String.t(), String.t(), binary()}
  def generate do
    public_part =
      @api_key_public_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    secret =
      @api_key_secret_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    key_prefix = "#{@api_key_prefix_scheme}-#{public_part}"
    {key_prefix, "#{key_prefix}-#{secret}", hash_secret(secret)}
  end

  @spec hash_secret(binary()) :: binary()
  def hash_secret(secret), do: :crypto.hash(:sha256, secret)

  @spec split(term()) ::
          {:ok, String.t(), String.t()} | {:error, :empty_api_key | :invalid_api_key}
  def split(raw_key) when is_binary(raw_key) do
    key = String.trim(raw_key)

    cond do
      key == "" ->
        {:error, :empty_api_key}

      String.starts_with?(key, @api_key_prefix_scheme <> "-") ->
        case String.replace_prefix(key, @api_key_prefix_scheme <> "-", "")
             |> String.split("-", parts: 2) do
          [public_part, secret] when public_part != "" and secret != "" ->
            {:ok, "#{@api_key_prefix_scheme}-#{public_part}", secret}

          _parts ->
            {:error, :invalid_api_key}
        end

      true ->
        {:error, :invalid_api_key}
    end
  end

  def split(_raw_key), do: {:error, :invalid_api_key}

  @spec verify(binary(), binary()) :: :ok | :invalid_secret
  def verify(expected_hash, secret) when is_binary(expected_hash) and is_binary(secret) do
    actual_hash = hash_secret(secret)

    if byte_size(expected_hash) == byte_size(actual_hash) and
         Plug.Crypto.secure_compare(expected_hash, actual_hash) do
      :ok
    else
      :invalid_secret
    end
  end

  def verify(_expected_hash, _secret), do: :invalid_secret
end
