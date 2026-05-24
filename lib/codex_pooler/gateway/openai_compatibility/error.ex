defmodule CodexPooler.Gateway.OpenAICompatibility.Error do
  @moduledoc false

  @type reason :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:param) => String.t() | nil
        }

  @spec reason(pos_integer(), String.t() | atom(), String.t(), String.t() | nil) :: reason()
  def reason(status, code, message, param \\ nil) do
    %{status: status, code: to_string(code), message: message, param: param}
  end

  @spec unsupported_parameter(String.t()) :: reason()
  def unsupported_parameter(param) do
    reason(400, "unsupported_parameter", "Unsupported parameter: #{param}", param)
  end

  @spec invalid_request(String.t(), String.t() | nil) :: reason()
  def invalid_request(message, param \\ nil) do
    reason(400, "invalid_request", message, param)
  end

  @spec invalid_model(String.t()) :: reason()
  def invalid_model(message \\ "model is not supported by this compatibility adapter") do
    reason(400, "invalid_model", message, "model")
  end
end
