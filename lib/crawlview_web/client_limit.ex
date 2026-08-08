defmodule CrawlviewWeb.ClientLimit do
  @moduledoc """
  Decides whether a client may start another crawl, and knows how to recognise a
  client in the first place.

  Split from `CrawlviewWeb.RateLimit` because they answer different questions. The
  limiter counts requests against a key; this module decides what the key IS, which
  is the part that depends on how the app is deployed and is the part that is easy
  to get quietly wrong.
  """

  alias CrawlviewWeb.RateLimit

  @default_limit 5
  @default_window_ms 60_000

  @doc """
  Records an attempt and says whether it is allowed.

  Accepts a connection, so the API can ask directly, or an already-derived key, which
  is what a LiveView holds: `get_connect_info/2` only works while mounting, so the
  key is computed once at mount and kept.
  """
  @spec allow(Plug.Conn.t() | String.t()) :: :ok | {:error, :rate_limited}
  def allow(%Plug.Conn{} = conn), do: conn |> client_key() |> allow()

  def allow(key) when is_binary(key) do
    RateLimit.take(key, limit(), window_ms())
  end

  @doc """
  Identifies the client behind a connection or a LiveView socket.

  Behind a proxy, `remote_ip` is the PROXY's address, the same value for everybody,
  so a limiter keyed on it throttles all visitors as if they were one person. The
  client's real address arrives in `x-forwarded-for` instead.

  Which entry of that header to trust is the subtle part. A client can send its own
  `x-forwarded-for`, and the proxy appends what it actually saw, so the leftmost entry
  is attacker-controlled and the RIGHTMOST is the one our own proxy wrote. Taking the
  last entry is therefore correct behind exactly one trusted proxy, which is how this
  is deployed. Behind two, the index would have to change, and that is worth knowing
  before anyone puts a CDN in front of it.
  """
  @spec client_key(Plug.Conn.t() | Phoenix.LiveView.Socket.t()) :: String.t()
  def client_key(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] -> address_string(conn.remote_ip)
      forwarded -> forwarded |> List.last() |> String.split(",") |> List.last() |> String.trim()
    end
  end

  def client_key(socket) do
    forwarded =
      socket
      |> Phoenix.LiveView.get_connect_info(:x_headers)
      |> List.wrap()
      |> Enum.filter(fn {name, _value} -> name == "x-forwarded-for" end)
      |> Enum.map(fn {_name, value} -> value end)

    case forwarded do
      [] ->
        case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
          %{address: address} -> address_string(address)
          _unavailable -> "unknown"
        end

      values ->
        values |> List.last() |> String.split(",") |> List.last() |> String.trim()
    end
  end

  defp address_string(address) when is_tuple(address), do: to_string(:inet.ntoa(address))
  defp address_string(_address), do: "unknown"

  defp limit, do: Application.get_env(:crawlview, :client_crawl_limit, @default_limit)

  defp window_ms,
    do: Application.get_env(:crawlview, :client_crawl_window_ms, @default_window_ms)
end
