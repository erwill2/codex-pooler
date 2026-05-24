defmodule CodexPooler.Events.Event do
  @moduledoc "Pool-scoped LiveView invalidation event."

  @enforce_keys [:version, :id, :pool_id, :topics, :reason, :emitted_at, :payload]
  defstruct [:version, :id, :pool_id, :topics, :reason, :emitted_at, :payload]

  @type t :: %__MODULE__{
          version: pos_integer(),
          id: Ecto.UUID.t(),
          pool_id: Ecto.UUID.t(),
          topics: [String.t()],
          reason: String.t(),
          emitted_at: DateTime.t(),
          payload: map()
        }
end
