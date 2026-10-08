defmodule CodexPooler.Repo.Migrations.AllowPersistentReasoningEffort do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_reasoning_effort_check
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_reasoning_effort_check
    CHECK (enforced_reasoning_effort IS NULL OR enforced_reasoning_effort = ANY (ARRAY['none'::text, 'minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text, 'max'::text, 'ultra'::text, 'persistent'::text]))
    """

    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_maximum_reasoning_effort_check
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_maximum_reasoning_effort_check
    CHECK (maximum_reasoning_effort IS NULL OR maximum_reasoning_effort = ANY (ARRAY['none'::text, 'minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text, 'max'::text, 'ultra'::text, 'persistent'::text]))
    """
  end

  def down do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_reasoning_effort_check
    """

    execute """
    UPDATE api_keys
    SET enforced_reasoning_effort = NULL
    WHERE enforced_reasoning_effort = 'persistent'
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_reasoning_effort_check
    CHECK (enforced_reasoning_effort IS NULL OR enforced_reasoning_effort = ANY (ARRAY['none'::text, 'minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text, 'max'::text, 'ultra'::text]))
    """

    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_maximum_reasoning_effort_check
    """

    execute """
    UPDATE api_keys
    SET maximum_reasoning_effort = NULL
    WHERE maximum_reasoning_effort = 'persistent'
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_maximum_reasoning_effort_check
    CHECK (maximum_reasoning_effort IS NULL OR maximum_reasoning_effort = ANY (ARRAY['none'::text, 'minimal'::text, 'low'::text, 'medium'::text, 'high'::text, 'xhigh'::text, 'max'::text, 'ultra'::text]))
    """
  end
end
