defmodule CodexPooler.MCP.Tools.Placeholder do
  @moduledoc """
  Safe unavailable handler for catalog-reserved metadata tools.
  """

  @spec output_schema() :: map()
  def output_schema do
    %{
      "type" => "object",
      "required" => ["error"],
      "additionalProperties" => false,
      "properties" => %{
        "error" => %{
          "type" => "object",
          "required" => ["code", "message"],
          "additionalProperties" => false,
          "properties" => %{
            "code" => %{"type" => "string"},
            "message" => %{"type" => "string"}
          }
        }
      }
    }
  end

  @spec call(map(), map()) :: {:error, map()}
  def call(_arguments, %{tool: %{title: title}}) do
    {:error, unavailable(title)}
  end

  def call(_arguments, _context) do
    {:error, unavailable("MCP metadata tool")}
  end

  defp unavailable(title) do
    %{
      code: :not_implemented,
      message: "#{title} is advertised for catalog compatibility but not implemented until Task 7"
    }
  end
end
