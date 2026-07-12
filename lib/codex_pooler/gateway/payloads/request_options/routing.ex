defmodule CodexPooler.Gateway.Payloads.RequestOptions.Routing do
  @moduledoc false

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision

  defstruct [
    :requested_model,
    :effective_model,
    :api_key_policy,
    :file_affinity_assignment_id,
    :prompt_cache_key,
    :quota_decision,
    :reasoning_effort_decision,
    :routing_attempt_metadata,
    :routing_circuit_state,
    :use_responses_lite?
  ]

  @type t :: %__MODULE__{
          requested_model: String.t() | nil,
          effective_model: String.t() | nil,
          api_key_policy: map() | nil,
          file_affinity_assignment_id: Ecto.UUID.t() | nil,
          prompt_cache_key: String.t() | nil,
          quota_decision: map() | nil,
          reasoning_effort_decision: Decision.t() | nil,
          routing_attempt_metadata: map() | nil,
          routing_circuit_state: term(),
          use_responses_lite?: boolean()
        }
end
