defmodule CodexPoolerWeb.Plugs.RuntimeIngress.Firewall do
  @moduledoc false

  import Bitwise
  import Plug.Conn

  alias CodexPooler.Gateway.OperationalSettings

  @type conn :: Plug.Conn.t()
  @type firewall_error :: %{
          required(:status) => 403,
          required(:code) => String.t(),
          required(:message) => String.t()
        }
  @type ip_address :: :inet.ip_address()
  @type settings :: OperationalSettings.t()

  @spec enforce(conn(), settings()) :: {:ok, conn()} | {:error, firewall_error()}
  def enforce(conn, settings) do
    if OperationalSettings.firewall_enabled?(settings) do
      client_ip = client_ip(conn, settings)

      if ip_allowed?(client_ip, settings.firewall_allowlist) do
        {:ok, %{conn | remote_ip: client_ip}}
      else
        {:error, %{status: 403, code: "access_denied", message: "client IP is not allowed"}}
      end
    else
      {:ok, conn}
    end
  end

  @spec client_ip(conn(), settings()) :: ip_address()
  def client_ip(conn, settings) do
    if ip_allowed?(conn.remote_ip, settings.trusted_proxies) do
      forwarded_client_ip(conn, settings) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  defp forwarded_client_ip(conn, settings) do
    conn
    |> get_req_header("x-forwarded-for")
    |> forwarded_for_ip(settings)
    |> case do
      nil -> conn |> get_req_header("x-real-ip") |> List.first() |> parse_ip()
      ip -> ip
    end
  end

  defp forwarded_for_ip([], _settings), do: nil

  defp forwarded_for_ip(values, settings) do
    values
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.map(&parse_ip/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
    |> Enum.drop_while(&ip_allowed?(&1, settings.trusted_proxies))
    |> List.first()
  end

  defp ip_allowed?(ip, rules) do
    Enum.any?(rules, &ip_matches_rule?(ip, &1))
  end

  defp ip_matches_rule?(ip, rule) do
    case parse_rule(rule) do
      {:ip, rule_ip} -> ip == rule_ip
      {:cidr, network, prefix} -> cidr_match?(ip, network, prefix)
      :error -> false
    end
  end

  defp parse_rule(rule) do
    case String.split(rule, "/", parts: 2) do
      [address] ->
        case parse_ip(address) do
          nil -> :error
          ip -> {:ip, ip}
        end

      [address, prefix] ->
        with ip when not is_nil(ip) <- parse_ip(address),
             {prefix, ""} <- Integer.parse(prefix),
             true <- valid_prefix?(ip, prefix) do
          {:cidr, ip, prefix}
        else
          _invalid -> :error
        end
    end
  end

  defp parse_ip(nil), do: nil

  defp parse_ip(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp valid_prefix?(ip, prefix), do: prefix >= 0 and prefix <= ip_total_bits(ip)

  defp cidr_match?(ip, network, prefix) when tuple_size(ip) == tuple_size(network) do
    ip_bits = ip_to_integer(ip)
    network_bits = ip_to_integer(network)
    total_bits = ip_total_bits(ip)
    mask = mask(total_bits, prefix)
    Bitwise.band(ip_bits, mask) == Bitwise.band(network_bits, mask)
  end

  defp cidr_match?(_ip, _network, _prefix), do: false

  defp ip_to_integer(ip) do
    bits_per_segment = ip_segment_bits(ip)

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< bits_per_segment) + part end)
  end

  defp ip_total_bits(ip), do: tuple_size(ip) * ip_segment_bits(ip)
  defp ip_segment_bits(ip) when tuple_size(ip) == 4, do: 8
  defp ip_segment_bits(ip) when tuple_size(ip) == 8, do: 16

  defp mask(_total_bits, 0), do: 0

  defp mask(total_bits, prefix) do
    ((1 <<< prefix) - 1) <<< (total_bits - prefix)
  end
end
