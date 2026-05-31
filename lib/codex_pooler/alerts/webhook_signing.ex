defmodule CodexPooler.Alerts.WebhookSigning do
  @moduledoc false

  @type signature :: String.t()

  @spec sign(binary(), binary(), binary(), binary()) :: signature()
  def sign(event_id, attempt_id, raw_json_body, signing_secret)
      when is_binary(event_id) and is_binary(attempt_id) and is_binary(raw_json_body) and
             is_binary(signing_secret) do
    base_string = event_id <> "." <> attempt_id <> "." <> raw_json_body
    digest = :crypto.mac(:hmac, :sha256, signing_secret, base_string)

    "sha256=" <> Base.encode16(digest, case: :lower)
  end

  @spec verify?(binary(), binary(), binary(), binary(), signature()) :: boolean()
  def verify?(
        event_id,
        attempt_id,
        raw_json_body,
        signing_secret,
        "sha256=" <> _digest = signature
      )
      when is_binary(signing_secret) do
    Plug.Crypto.secure_compare(
      sign(event_id, attempt_id, raw_json_body, signing_secret),
      signature
    )
  end

  def verify?(_event_id, _attempt_id, _raw_json_body, _signing_secret, _signature), do: false
end
