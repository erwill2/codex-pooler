defmodule CodexPooler.Gateway.OpenAICompatibility.Matrix do
  @moduledoc false

  @fields %{
    responses:
      ~w(model instructions input tools tool_choice parallel_tool_calls reasoning text stream store include service_tier prompt_cache_key client_metadata previous_response_id metadata),
    chat:
      ~w(model messages tools tool_choice parallel_tool_calls response_format stream temperature top_p max_tokens max_completion_tokens),
    files: ~w(file purpose),
    audio: ~w(file model language prompt response_format temperature),
    images:
      ~w(model prompt size quality background input_fidelity n image image[] mask response_format user)
  }

  @spec supported_fields(atom()) :: [String.t()]
  def supported_fields(adapter), do: Map.fetch!(@fields, adapter)

  @spec supported_field_matrix() :: %{atom() => [String.t()]}
  def supported_field_matrix, do: @fields
end
