defmodule CodexPooler.MCP.Material do
  @moduledoc false

  @token_prefix_scheme "mcp-cxp"
  @token_public_bytes 6
  @token_secret_bytes 32

  @spec generate() :: {String.t(), String.t(), binary()}
  def generate do
    public_part =
      @token_public_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    secret =
      @token_secret_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    key_prefix = "#{@token_prefix_scheme}-#{public_part}"
    {key_prefix, "#{key_prefix}-#{secret}", hash_secret(secret)}
  end

  @spec hash_secret(binary()) :: binary()
  def hash_secret(secret), do: :crypto.hash(:sha256, secret)

  @spec split(term()) :: {:ok, String.t(), String.t()} | {:error, atom()}
  def split(raw_token) when is_binary(raw_token) do
    token = String.trim(raw_token)

    cond do
      token == "" ->
        {:error, :empty_mcp_token}

      String.starts_with?(token, @token_prefix_scheme <> "-") ->
        case token
             |> String.replace_prefix(@token_prefix_scheme <> "-", "")
             |> String.split("-", parts: 2) do
          [public_part, secret] when public_part != "" and secret != "" ->
            {:ok, "#{@token_prefix_scheme}-#{public_part}", secret}

          _parts ->
            {:error, :invalid_mcp_token}
        end

      true ->
        {:error, :invalid_mcp_token}
    end
  end

  def split(_raw_token), do: {:error, :invalid_mcp_token}

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
