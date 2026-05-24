defmodule CodexPoolerWeb.Admin.AvatarComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  @gravatar_avatar_base_url "https://www.gravatar.com/avatar/"
  @gravatar_default "identicon"
  @gravatar_rating "g"

  attr :id, :string, required: true
  attr :email, :string, required: true
  attr :label, :string, required: true
  attr :size, :integer, default: 80
  attr :class, :any, default: nil
  attr :image_class, :any, default: "size-10 rounded-full ring-1 ring-base-300"
  attr :rest, :global

  def gravatar(assigns) do
    assigns = assign(assigns, :avatar_url, gravatar_url(assigns.email, size: assigns.size))

    ~H"""
    <div id={@id} class={["avatar", @class]} title={@label} aria-label={@label} {@rest}>
      <div class={@image_class}>
        <img
          src={@avatar_url}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          aria-hidden="true"
        />
      </div>
    </div>
    """
  end

  @spec gravatar_url(term(), keyword()) :: String.t()
  def gravatar_url(email, opts \\ []) do
    size = opts |> Keyword.get(:size, 80) |> normalize_size()
    hash = email |> normalize_email() |> sha256()

    query =
      URI.encode_query(
        s: Integer.to_string(size),
        d: @gravatar_default,
        r: @gravatar_rating
      )

    @gravatar_avatar_base_url <> hash <> "?" <> query
  end

  @spec email_identity(term()) :: String.t() | nil
  def email_identity(value) when is_binary(value) do
    value
    |> String.replace(~r/^[^:]+:\s*/, "")
    |> String.trim()
    |> case do
      "" -> nil
      email -> if String.match?(email, ~r/^[^\s@]+@[^\s@]+$/), do: email
    end
  end

  def email_identity(_value), do: nil

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(_email), do: ""

  defp normalize_size(size) when is_integer(size), do: size |> max(1) |> min(2048)
  defp normalize_size(_size), do: 80

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
