defmodule Crawlview.Robots do
  @moduledoc """
  Loads a site's robots policy and answers permission and pacing questions.

  This is intentionally a small robots.txt subset. It does not implement `*` or
  `$` wildcards in rule paths, `Sitemap:`, `Request-rate`, user-agent wildcard
  patterns other than the literal `*`, or encoding/BOM handling beyond what Req
  provides. Rules are literal path-prefix matches.

  A missing robots.txt is a normal, common, meaningful absence, not a failure:
  most sites do not publish one. Consequently all fetch, status, and parse
  problems produce the same permissive policy as an absent file.
  """

  @crawler_token "crawlview"

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

  The public API deliberately remains the three functions in this module. Tests
  can stub the single request by temporarily setting Req's default `:plug`
  option to a `Req.Test` plug; `Req.get/1` merges those defaults. That provides a
  network seam without exposing the parser or adding options to the policy API.
  """
  @spec load(root_url :: String.t()) :: t()
  def load(root_url) do
    try do
      with {:ok, robots_url} <- robots_url(root_url),
           {:ok, %Req.Response{status: 200, body: body}} <- Req.get(url: robots_url),
           {:ok, policy} <- parse(body) do
        policy
      else
        _reason -> permissive()
      end
    rescue
      _exception -> permissive()
    catch
      _kind, _reason -> permissive()
    end
  end

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

  defp permissive, do: %__MODULE__{}

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

  defp parse(body) when is_binary(body) do
    groups =
      body
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.reduce({[], nil}, &parse_line/2)
      |> finish_groups()

    group =
      Enum.find(groups, &(@crawler_token in &1.agents)) ||
        Enum.find(groups, &("*" in &1.agents))

    case group do
      nil -> {:ok, permissive()}
      selected -> {:ok, %__MODULE__{rules: selected.rules, crawl_delay_ms: selected.delay_ms}}
    end
  end

  defp parse(_body), do: :error

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
