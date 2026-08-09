defmodule Crawlview.Robots do
  @moduledoc """
  Loads a site's robots policy and answers permission and pacing questions.

  This is intentionally a small robots.txt subset. It does not implement `*` or
  `$` wildcards in rule paths, `Sitemap:`, `Request-rate`, user-agent wildcard
  patterns other than the literal `*`, or encoding/BOM handling. Rules are
  literal path-prefix matches.

  A missing robots.txt is a normal, common, meaningful absence, not a failure:
  most sites do not publish one. Consequently all fetch, status, and parse
  problems produce the same permissive policy as an absent file.
  """

  alias Crawlview.Fetcher
  alias Crawlview.Fetcher.Result

  @crawler_token "crawlview"
  @max_redirects 3

  @opaque t() :: %__MODULE__{
            rules: [{:allow | :disallow, String.t()}],
            crawl_delay_ms: non_neg_integer()
          }

  defstruct rules: [], crawl_delay_ms: 0

  @doc """
  Fetches the robots.txt at the site root derived from `root_url`.

  This function always returns a policy. Missing files, non-200 responses,
  transport errors, and bodies that cannot be parsed all return a permissive
  policy.
  """
  @spec load(root_url :: String.t()) :: t()
  def load(root_url) do
    case robots_url(root_url) do
      {:ok, robots_url} -> load_url(robots_url, @max_redirects)
      _invalid_url -> permissive()
    end
  rescue
    _exception -> permissive()
  catch
    _kind, _reason -> permissive()
  end

  @doc """
  Parses a robots.txt body into a policy.

  Unsupported or malformed content is interpreted leniently. Non-binary input
  returns the same permissive policy as an absent robots.txt.
  """
  @spec parse(binary()) :: t()
  def parse(body) when is_binary(body) do
    do_parse(body)
  rescue
    _exception -> permissive()
  catch
    _kind, _reason -> permissive()
  end

  def parse(_body), do: permissive()

  defp do_parse(body) do
    groups =
      body
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.reduce({[], nil}, &parse_line/2)
      |> finish_groups()

    group =
      Enum.find(groups, &(@crawler_token in &1.agents)) ||
        Enum.find(groups, &("*" in &1.agents))

    case group do
      nil -> permissive()
      selected -> %__MODULE__{rules: selected.rules, crawl_delay_ms: selected.delay_ms}
    end
  end

  @doc "Returns a policy that permits every URL with no crawl delay."
  @spec permissive() :: t()
  def permissive, do: %__MODULE__{}

  @doc """
  Returns whether `url` is permitted by the loaded policy.

  Matching uses only the URL's path and query. The longest matching Allow or
  Disallow path wins; an equally long tie favors Allow, matching the de facto
  convention used by other crawlers.
  """
  @spec allowed?(t(), url :: String.t()) :: boolean()
  def allowed?(%__MODULE__{rules: rules}, url) do
    path_and_query = path_and_query(url)

    case matching_rule(rules, path_and_query) do
      {:disallow, _path} -> false
      _allow_or_no_rule -> true
    end
  end

  @doc """
  Returns the selected group's crawl delay in milliseconds, or `0` when absent.

  Robots.txt specifies crawl delay in seconds. Conversion to milliseconds and
  rounding to the nearest millisecond happen while the file is parsed.
  """
  @spec crawl_delay(t()) :: non_neg_integer()
  def crawl_delay(%__MODULE__{crawl_delay_ms: delay}), do: delay

  defp load_url(url, redirects_left) do
    # Unlike ["text/plain"], :any accepts misleading or missing media types at
    # this well-known path; lenient parsing and the byte cap are what protect us.
    case Fetcher.fetch(url, accept: :any, max_bytes: 512_000) do
      %Result{outcome: :ok, body: body} ->
        parse(body)

      %Result{outcome: :redirect, redirect_to: target}
      when redirects_left > 0 ->
        if safe_redirect?(url, target) do
          load_url(target, redirects_left - 1)
        else
          permissive()
        end

      _other_outcome ->
        permissive()
    end
  end

  defp safe_redirect?(requested_url, target_url) do
    with %URI{host: requested_host} when is_binary(requested_host) <- URI.parse(requested_url),
         %URI{scheme: scheme, host: target_host}
         when scheme in ["http", "https"] and is_binary(target_host) <- URI.parse(target_url) do
      # Only the root host passed Url.public_http_url/1; another name could resolve
      # to an address that nobody validated, the same hole exact-host scoping closes.
      String.downcase(requested_host) == String.downcase(target_host)
    else
      _invalid_url -> false
    end
  end

  defp robots_url(root_url) when is_binary(root_url) do
    case URI.parse(root_url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok,
         URI.to_string(%URI{
           scheme: scheme,
           host: host,
           port: uri.port,
           path: "/robots.txt"
         })}

      _invalid_url ->
        :error
    end
  end

  defp robots_url(_root_url), do: :error

  defp parse_line(line, state) do
    line =
      line
      |> strip_comment()
      |> String.trim()

    case split_record(line) do
      {"user-agent", agent} -> add_agent(state, String.downcase(agent))
      {name, value} -> add_directive(state, name, value)
      :blank_or_invalid -> state
    end
  end

  defp strip_comment(line) do
    case :binary.split(line, "#") do
      [content | _rest] -> content
      [] -> line
    end
  end

  defp split_record(""), do: :blank_or_invalid

  defp split_record(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> {name |> String.trim() |> String.downcase(), String.trim(value)}
      _invalid -> :blank_or_invalid
    end
  end

  defp add_agent({groups, nil}, agent),
    do: {groups, new_group(agent)}

  defp add_agent({groups, %{directives?: false} = group}, agent),
    do: {groups, %{group | agents: group.agents ++ [agent]}}

  defp add_agent({groups, group}, agent),
    do: {[group | groups], new_group(agent)}

  defp new_group(agent) do
    %{agents: [agent], rules: [], delay_ms: 0, delay_seen?: false, directives?: false}
  end

  defp add_directive({groups, nil}, _name, _value), do: {groups, nil}

  defp add_directive({groups, group}, name, value) do
    group = %{group | directives?: true}

    group =
      case name do
        "allow" -> add_rule(group, :allow, value)
        "disallow" -> add_rule(group, :disallow, value)
        "crawl-delay" -> add_delay(group, value)
        _unsupported -> group
      end

    {groups, group}
  end

  defp add_rule(group, :disallow, "") do
    # Empty Disallow means "disallow nothing", not "disallow everything"; it
    # therefore contributes no matching rule.
    group
  end

  defp add_rule(group, kind, path), do: %{group | rules: group.rules ++ [{kind, path}]}

  defp add_delay(%{delay_seen?: true} = group, _value), do: group

  defp add_delay(group, value) do
    delay_ms =
      case Float.parse(value) do
        {seconds, rest} when seconds >= 0 ->
          if String.trim(rest) == "", do: round(seconds * 1_000), else: 0

        _invalid ->
          0
      end

    %{group | delay_ms: delay_ms, delay_seen?: true}
  end

  defp finish_groups({groups, nil}), do: Enum.reverse(groups)
  defp finish_groups({groups, group}), do: Enum.reverse([group | groups])

  defp path_and_query(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path, query: nil} -> path || "/"
      %URI{path: path, query: query} -> (path || "/") <> "?" <> query
    end
  rescue
    _exception -> "/"
  end

  defp path_and_query(_url), do: "/"

  defp matching_rule(rules, path_and_query) do
    rules
    |> Enum.filter(fn {_kind, path} ->
      path != "" and String.starts_with?(path_and_query, path)
    end)
    |> Enum.max_by(
      fn {kind, path} -> {byte_size(path), allow_priority(kind)} end,
      fn -> nil end
    )
  end

  defp allow_priority(:allow), do: 1
  defp allow_priority(:disallow), do: 0
end
