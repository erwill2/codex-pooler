defmodule CodexPooler.MCP.Tools.DetailEnvelope do
  @moduledoc false

  @schema %{
    "type" => "object",
    "required" => ["status", "kind", "item", "candidates", "message"],
    "additionalProperties" => false,
    "properties" => %{
      "status" => %{"type" => "string"},
      "kind" => %{"type" => "string"},
      "item" => %{"type" => ["object", "null"]},
      "candidates" => %{"type" => "array"},
      "message" => %{"type" => "string"}
    }
  }

  @spec output_schema() :: map()
  def output_schema, do: @schema

  @spec ok(String.t(), map()) :: map()
  def ok(kind, item) when is_binary(kind) and is_map(item) do
    %{
      "status" => "ok",
      "kind" => kind,
      "item" => item,
      "candidates" => [],
      "message" => ""
    }
  end

  @spec ambiguous(String.t(), [map()], String.t()) :: map()
  def ambiguous(kind, candidates, message) when is_binary(kind) and is_list(candidates) do
    %{
      "status" => "ambiguous",
      "kind" => kind,
      "item" => nil,
      "candidates" => candidates,
      "message" => message
    }
  end

  @spec not_found(String.t(), String.t()) :: map()
  def not_found(kind, message) when is_binary(kind) do
    %{
      "status" => "not_found",
      "kind" => kind,
      "item" => nil,
      "candidates" => [],
      "message" => message
    }
  end
end
