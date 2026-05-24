defmodule CodexPooler.Gateway.Payloads.ToolResultShape do
  @moduledoc false

  @type item :: %{type: String.t(), call_id: String.t()}

  @spec items(term()) :: [item()]
  def items(input) when is_list(input), do: Enum.flat_map(input, &items/1)

  def items(%{} = item) do
    nested = item |> Map.values() |> Enum.flat_map(&items/1)

    if tool_result?(item) do
      [
        %{
          type: clean_string(Map.get(item, "type")) || "unknown_tool_output",
          call_id: call_id(item)
        }
        | nested
      ]
    else
      nested
    end
  end

  def items(_input), do: []

  @spec tool_result?(term()) :: boolean()
  def tool_result?(%{} = item) do
    is_binary(call_id(item)) and tool_result_type?(Map.get(item, "type"), item)
  end

  def tool_result?(_item), do: false

  defp tool_result_type?(type, item) when is_binary(type) do
    normalized = type |> String.trim() |> String.downcase()

    String.ends_with?(normalized, "_output") or Map.has_key?(item, "output") or
      Map.has_key?(item, "result")
  end

  defp tool_result_type?(_type, item),
    do: Map.has_key?(item, "output") or Map.has_key?(item, "result")

  defp call_id(%{} = item), do: clean_string(Map.get(item, "call_id"))

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil
end
