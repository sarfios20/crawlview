defmodule Crawlview.Url do
  @moduledoc """
  Decides which URLs are visitable within a crawl and canonicalizes them.

  This module knows nothing about HTTP, HTML, or how a crawl is performed.
  """

  @doc """
  Resolves raw hrefs against `base` and returns canonical URLs belonging to
  the site identified by `root`.

  Invalid, unsupported, fragment-only, and off-site values are omitted. The
  result is deduplicated while retaining the first occurrence's document
  position.
  """
  @spec visitable([String.t()], base :: String.t(), root :: String.t()) :: [String.t()]
  def visitable(hrefs, base, root) do
    # Each returned string is the crawl-wide deduplication key. Consequently,
    # every normalization rule here affects whether the crawler revisits a page
    # or recognizes two references as the same page.
    try do
      with %URI{} = base_uri <- parse_http_uri(base),
           %URI{host: root_host} <- parse_http_uri(root) do
        {urls, _seen} =
          Enum.reduce(hrefs, {[], MapSet.new()}, fn href, {urls, seen} ->
            case canonical_url(href, base_uri, root_host) do
              nil ->
                {urls, seen}

              url ->
                if MapSet.member?(seen, url) do
                  {urls, seen}
                else
                  {[url | urls], MapSet.put(seen, url)}
                end
            end
          end)

        Enum.reverse(urls)
      else
        _ -> []
      end
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp parse_http_uri(value) do
    uri = value |> String.trim() |> URI.parse()
    scheme = uri.scheme && String.downcase(uri.scheme)
    host = uri.host && String.downcase(uri.host)

    if scheme in ["http", "https"] and credible_host?(host) and valid_port?(uri.port) and
         encoded_component?(uri.path) and encoded_component?(uri.query) and
         encoded_component?(uri.userinfo) do
      %{uri | scheme: scheme, host: host, fragment: nil}
    end
  end

  defp canonical_url(href, base_uri, root_host) do
    try do
      trimmed = String.trim(href)

      if trimmed == "" or String.starts_with?(trimmed, "#") do
        nil
      else
        uri = URI.merge(base_uri, trimmed)
        scheme = uri.scheme && String.downcase(uri.scheme)
        host = uri.host && String.downcase(uri.host)

        if scheme in ["http", "https"] and credible_host?(host) and
             site_key(host) == site_key(root_host) and valid_port?(uri.port) and
             encoded_component?(uri.path) and encoded_component?(uri.query) and
             encoded_component?(uri.userinfo) do
          # Emit the root's spelling of the host, not the link's. Once site_key/1
          # has judged the two hosts to be the same site, keeping both spellings
          # would hand the crawl two different deduplication keys for one page and
          # break the invariant this function exists to uphold. The scheme is left
          # as written, because http and https genuinely can serve different bytes
          # and a redirect between them is information worth recording.
          uri
          |> Map.put(:scheme, scheme)
          |> Map.put(:host, root_host)
          |> Map.put(:port, canonical_port(scheme, uri.port))
          |> Map.put(:path, canonical_path(uri.path))
          |> Map.put(:query, canonical_query(uri.query))
          |> Map.put(:fragment, nil)
          |> URI.to_string()
        end
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  # A leading www. is ignored for crawl membership so apex/www redirects do
  # not split a typical site. This can rarely conflate genuinely distinct
  # services on those two hosts, an accepted tradeoff for this crawler's scope.
  defp site_key("www." <> host), do: host
  defp site_key(host), do: host

  defp credible_host?(host) when is_binary(host) do
    cond do
      not String.valid?(host) or host == "" ->
        false

      String.contains?(host, ":") ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, address} when tuple_size(address) == 8 -> true
          _ -> false
        end

      true ->
        Regex.match?(~r/^[\p{L}\p{M}\p{N}.-]+$/u, host) and
          host |> String.trim_trailing(".") |> String.split(".") |> Enum.all?(&(&1 != ""))
    end
  end

  defp credible_host?(_host), do: false

  defp valid_port?(nil), do: true
  defp valid_port?(port) when is_integer(port), do: port in 1..65_535
  defp valid_port?(_port), do: false

  defp canonical_port("http", 80), do: nil
  defp canonical_port("https", 443), do: nil
  defp canonical_port(_scheme, port), do: port

  defp canonical_path(path) do
    path =
      case path do
        nil -> "/"
        "" -> "/"
        value -> value
      end

    # Trailing-slash-stripped is the canonical form; the origin root remains
    # "/" because an HTTP authority with no path denotes that same resource.
    path = if path == "/", do: path, else: String.trim_trailing(path, "/")
    path = Regex.replace(~r{/index\.html?$}, path, "")

    case String.trim_trailing(path, "/") do
      "" -> "/"
      canonical -> canonical
    end
  end

  defp canonical_query(nil), do: nil
  defp canonical_query(""), do: nil

  defp canonical_query(query) do
    query
    |> String.split("&", trim: false)
    |> Enum.with_index()
    |> Enum.sort_by(fn {parameter, position} -> {query_key(parameter), position} end)
    |> Enum.map_join("&", fn {parameter, _position} -> parameter end)
  end

  defp query_key(parameter) do
    case :binary.split(parameter, "=") do
      [key, _value] -> key
      [key] -> key
    end
  end

  defp encoded_component?(nil), do: true

  defp encoded_component?(component) when is_binary(component) do
    String.valid?(component) and not Regex.match?(~r/[\x00-\x20\x7F]/, component) and
      component
      |> String.replace(~r/%[[:xdigit:]]{2}/, "")
      |> String.contains?("%")
      |> Kernel.not()
  end

  defp encoded_component?(_component), do: false

  # Human-entered crawl roots need explicit rejection reasons and an SSRF
  # boundary. This is intentionally separate from visitable/3, whose job is to
  # silently discard unsuitable hrefs found in scraped documents.
  #
  # DNS rebinding remains a known and accepted gap: DNS can change between this
  # one-time validation and a later HTTP request. This protects a person from
  # being tricked into submitting a host that currently resolves internally; it
  # does not defend against an adversarial DNS server racing the crawler.
  @doc """
  Validates and canonicalizes a human-entered HTTP or HTTPS crawl root.
  """
  @spec public_http_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def public_http_url(value) when is_binary(value) do
    try do
      uri = value |> String.trim() |> URI.parse()
      scheme = uri.scheme && String.downcase(uri.scheme)

      cond do
        scheme not in ["http", "https"] ->
          {:error, :invalid_scheme}

        not valid_public_uri?(uri) ->
          {:error, :invalid_url}

        true ->
          uri = %{uri | scheme: scheme, host: String.downcase(uri.host)}

          case resolved_addresses(uri.host) do
            nil ->
              {:error, :unresolvable}

            addresses ->
              if Enum.any?(addresses, &unsafe_address?/1) do
                {:error, :private_address}
              else
                {:ok, canonical_public_url(uri)}
              end
          end
      end
    rescue
      _ -> {:error, :invalid_url}
    catch
      _, _ -> {:error, :invalid_url}
    end
  end

  def public_http_url(_value), do: {:error, :invalid_url}

  defp valid_public_uri?(uri) do
    credible_host?(uri.host) and valid_port?(uri.port) and encoded_component?(uri.path) and
      encoded_component?(uri.query) and encoded_component?(uri.userinfo)
  end

  defp canonical_public_url(uri) do
    uri
    |> Map.put(:port, canonical_port(uri.scheme, uri.port))
    |> Map.put(:path, canonical_path(uri.path))
    |> Map.put(:query, canonical_query(uri.query))
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp resolved_addresses(host) do
    host_charlist = String.to_charlist(host)

    case :inet.parse_address(host_charlist) do
      {:ok, address} ->
        [address]

      {:error, _reason} ->
        addresses =
          [
            :inet.getaddrs(host_charlist, :inet),
            :inet.getaddrs(host_charlist, :inet6)
          ]
          |> Enum.flat_map(fn
            {:ok, family_addresses} -> family_addresses
            {:error, _reason} -> []
          end)

        if addresses == [], do: nil, else: addresses
    end
  end

  # These exclusions deliberately cover destinations that must not be reached
  # through a user-supplied crawl root. Each clause encodes an IANA/RFC-defined
  # allocation so the security policy stays visible beside its bit boundaries:
  #
  #   * 127.0.0.0/8 is loopback (RFC 1122).
  #   * 10.0.0.0/8, 172.16.0.0/12, and 192.168.0.0/16 are private (RFC 1918).
  #   * 169.254.0.0/16 is IPv4 link-local (RFC 3927).
  #   * 0.0.0.0/8 is the current network/unspecified block (RFC 1122).
  #   * 100.64.0.0/10 is shared carrier-grade NAT space (RFC 6598).
  #   * 224.0.0.0/4 and higher are multicast or reserved (RFC 5771/IANA).
  #   * ::1 is IPv6 loopback (RFC 4291).
  #   * fc00::/7 is unique-local space (RFC 4193).
  #   * fe80::/10 is IPv6 link-local space (RFC 4291).
  #   * ff00::/8 is IPv6 multicast space (RFC 4291).
  #   * ::ffff:0:0/96 is IPv4-mapped IPv6 (RFC 4291); its embedded IPv4
  #     address must pass the IPv4 policy to prevent representation-based SSRF.
  defp unsafe_address?({127, _b, _c, _d}), do: true
  defp unsafe_address?({10, _b, _c, _d}), do: true
  defp unsafe_address?({172, b, _c, _d}) when b in 16..31, do: true
  defp unsafe_address?({192, 168, _c, _d}), do: true
  defp unsafe_address?({169, 254, _c, _d}), do: true
  defp unsafe_address?({0, _b, _c, _d}), do: true
  defp unsafe_address?({100, b, _c, _d}) when b in 64..127, do: true
  defp unsafe_address?({a, _b, _c, _d}) when a >= 224, do: true

  defp unsafe_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    unsafe_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  defp unsafe_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp unsafe_address?({first, _b, _c, _d, _e, _f, _g, _h}) when first in 0xFC00..0xFDFF, do: true
  defp unsafe_address?({first, _b, _c, _d, _e, _f, _g, _h}) when first in 0xFE80..0xFEBF, do: true
  defp unsafe_address?({first, _b, _c, _d, _e, _f, _g, _h}) when first in 0xFF00..0xFFFF, do: true
  defp unsafe_address?(_address), do: false

  # This narrow escape hatch exists only so tests can exercise the pure,
  # security-sensitive address policy without coupling those tests to DNS.
  @doc false
  @spec __unsafe_address__(:inet.ip_address()) :: boolean()
  def __unsafe_address__(address), do: unsafe_address?(address)
end
