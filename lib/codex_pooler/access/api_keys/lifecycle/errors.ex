defmodule CodexPooler.Access.APIKeys.Errors do
  @moduledoc false

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec access_error(atom(), String.t()) :: access_error()
  def access_error(code, message), do: %{code: code, message: message}
end
