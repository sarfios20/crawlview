defmodule Crawlview.Fetcher.Result do
  @moduledoc """
  The normalized result of fetching one URL.

  `duration_ms` is elapsed time in milliseconds. `body`, when present, is the
  response body in bytes; the size limit applied to it is also expressed in bytes.
  """

  @type outcome ::
          :ok
          | :redirect
          | :not_found
          | :client_error
          | :server_error
          | :timeout
          | :unreachable
          | :not_html
          | :too_large

  @type t :: %__MODULE__{
          outcome: outcome(),
          status: pos_integer() | nil,
          content_type: String.t() | nil,
          redirect_to: String.t() | nil,
          body: binary() | nil,
          duration_ms: non_neg_integer()
        }

  @enforce_keys [:outcome, :status, :content_type, :redirect_to, :body, :duration_ms]
  defstruct outcome: nil,
            status: nil,
            content_type: nil,
            redirect_to: nil,
            body: nil,
            duration_ms: nil
end

defmodule Crawlview.Fetcher do
  @moduledoc """
  Fetches the bytes for one URL and normalizes every result behind one interface.

  Redirects are reported rather than followed, and response bodies are never
  interpreted as HTML beyond checking their media type.
  """

  alias Crawlview.Fetcher.Result

  @default_timeout_ms 10_000
  @default_max_bytes 2_000_000
  @user_agent "Crawlview/0.1 (+https://github.com/sarfios20/crawlview)"

  @doc """
  Fetches `url` once and returns a normalized result.

  Options:

    * `:timeout_ms` - connect and receive timeout in milliseconds; defaults to
      #{@default_timeout_ms}.
    * `:max_bytes` - maximum accepted response body size in bytes; defaults to
      #{@default_max_bytes}.
    * `:plug` - an optional Plug or `Req.Test` stub passed to the HTTP adapter.
      This is an intentional test seam: callers can substitute the byte source,
      but no Req request, response, or exception crosses this module boundary.
  """

  # Invariant: fetch/2 is total: it never raises and never returns an error tuple.
  # Fetching is a boundary operation with many routine failure modes; normalizing
  # them here avoids forcing every caller to understand and pattern-match changing
  # transport-library exceptions merely to continue its own work.
  @spec fetch(url :: String.t(), opts :: keyword()) :: %Crawlview.Fetcher.Result{}
  def fetch(url, opts \\ []) do
    # A monotonic clock measures elapsed milliseconds without being distorted by
    # wall-clock corrections such as NTP adjustments or daylight-saving changes.
    started_at = System.monotonic_time(:millisecond)

    # Option validation happens OUTSIDE the rescue below, and deliberately raises.
    # Totality is a promise about the network, not a promise to swallow programmer
    # error: a caller passing timeout_ms: "10s" has a bug, and reporting it as an
    # unreachable host would hide that bug behind a plausible-looking result.
    timeout_ms = positive_integer_option!(opts, :timeout_ms, @default_timeout_ms)
    max_bytes = non_negative_integer_option!(opts, :max_bytes, @default_max_bytes)

    result =
      try do
        do_fetch(url, opts, timeout_ms, max_bytes)
      rescue
        _exception -> transport_result(:unreachable)
      catch
        _kind, _reason -> transport_result(:unreachable)
      end

    %{result | duration_ms: elapsed_ms(started_at)}
  end

  defp do_fetch(url, opts, timeout_ms, max_bytes) do
    request_options = [
      url: url,
      method: :get,
      headers: [{"user-agent", @user_agent}],
      redirect: false,
      retry: false,
      receive_timeout: timeout_ms,
      connect_options: [timeout: timeout_ms],
      into: body_collector(max_bytes)
    ]

    # `:plug` is passed through only when supplied; it is the deliberate test seam
    # documented above and does not expose an HTTP-client value in the result.
    request_options =
      case Keyword.fetch(opts, :plug) do
        {:ok, plug} -> Keyword.put(request_options, :plug, plug)
        :error -> request_options
      end

    request_options
    |> Req.new()
    |> Req.request()
    |> normalize_request_result(url, max_bytes)
  end

  defp body_collector(max_bytes) do
    fn {:data, data}, {request, response} ->
      # Content-Length lets us halt near the start, while counting received bytes
      # protects against a missing or dishonest header. A single adapter chunk may
      # exceed the cap, so at worst that one max_bytes+epsilon chunk is received
      # before the stream is halted; it is never retained in the returned result.
      if content_length_too_large?(response, max_bytes) do
        {:halt, {request, %{response | body: :crawlview_too_large}}}
      else
        collect_or_reject_chunk(request, response, data, max_bytes)
      end
    end
  end

  defp collect_or_reject_chunk(request, response, data, max_bytes) do
    # Req's Finch adapter has populated status and headers by the first data
    # callback. Checking Content-Type here makes DESIGN.md's "bail after headers"
    # behavior real instead of waiting until the entire body has been buffered.
    # The adapter may still deliver this one non-HTML chunk before we can halt:
    # today's `into:` callback receives headers and data as separate messages and
    # offers no callback invocation on headers alone.
    if initial_body?(response.body) and definitely_not_html?(response) do
      {:halt, {request, %{response | body: :crawlview_not_html}}}
    else
      collect_chunk(request, response, data, max_bytes)
    end
  end

  defp collect_chunk(request, response, data, max_bytes) when is_binary(data) do
    {chunks, received_bytes} = body_state(response.body)
    next_size = received_bytes + byte_size(data)

    if next_size > max_bytes do
      {:halt, {request, %{response | body: :crawlview_too_large}}}
    else
      body = {:crawlview_body, [data | chunks], next_size}
      {:cont, {request, %{response | body: body}}}
    end
  end

  defp body_state({:crawlview_body, chunks, received_bytes}), do: {chunks, received_bytes}
  defp body_state(_initial_body), do: {[], 0}

  defp initial_body?({:crawlview_body, _chunks, _received_bytes}), do: false
  defp initial_body?(_initial_body), do: true

  defp definitely_not_html?(response) do
    case first_header(response, "content-type") do
      content_type when is_binary(content_type) ->
        media_type = content_type |> String.split(";", parts: 2) |> List.first() |> String.trim()

        valid_media_type?(media_type) and
          not html_content_type?(content_type)

      _missing_or_unparseable ->
        false
    end
  end

  defp valid_media_type?(media_type) do
    Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+\/[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, media_type)
  end

  defp normalize_request_result({:ok, response}, request_url, max_bytes) do
    status = response.status
    content_type = first_header(response, "content-type")
    location = first_header(response, "location")

    cond do
      response.body == :crawlview_too_large or
          content_length_too_large?(response, max_bytes) ->
        response_result(:too_large, status, content_type)

      status in 300..399 and is_binary(location) ->
        redirect_result(status, content_type, request_url, location)

      status == 404 ->
        response_result(:not_found, status, content_type)

      status in 400..499 ->
        response_result(:client_error, status, content_type)

      status in 500..599 ->
        response_result(:server_error, status, content_type)

      status in 200..299 and response.body == :crawlview_not_html ->
        response_result(:not_html, status, content_type)

      status in 200..299 and html_content_type?(content_type) ->
        ok_result(status, content_type, collected_body(response.body))

      status in 200..299 ->
        response_result(:not_html, status, content_type)

      status in 300..399 ->
        # A redirect without Location cannot be acted on. Treating that malformed
        # response as a client-side HTTP failure is the closest normalized outcome.
        response_result(:client_error, status, content_type)

      true ->
        response_result(:client_error, status, content_type)
    end
  end

  defp normalize_request_result({:error, reason}, _request_url, _max_bytes) do
    if timeout_reason?(reason) do
      transport_result(:timeout)
    else
      transport_result(:unreachable)
    end
  end

  defp normalize_request_result(_unexpected, _request_url, _max_bytes) do
    transport_result(:unreachable)
  end

  defp redirect_result(status, content_type, request_url, location) do
    case absolute_location(request_url, location) do
      {:ok, redirect_to} ->
        %Result{
          outcome: :redirect,
          status: status,
          content_type: content_type,
          redirect_to: redirect_to,
          body: nil,
          duration_ms: 0
        }

      :error ->
        response_result(:client_error, status, content_type)
    end
  end

  defp absolute_location(request_url, location) do
    try do
      {:ok, request_url |> URI.merge(location) |> URI.to_string()}
    rescue
      _exception -> :error
    end
  end

  defp ok_result(status, content_type, body) do
    %Result{
      outcome: :ok,
      status: status,
      content_type: content_type,
      redirect_to: nil,
      body: body,
      duration_ms: 0
    }
  end

  defp response_result(outcome, status, content_type) do
    %Result{
      outcome: outcome,
      status: status,
      content_type: content_type,
      redirect_to: nil,
      body: nil,
      duration_ms: 0
    }
  end

  defp transport_result(outcome) do
    %Result{
      outcome: outcome,
      status: nil,
      content_type: nil,
      redirect_to: nil,
      body: nil,
      duration_ms: 0
    }
  end

  defp collected_body({:crawlview_body, chunks, _received_bytes}) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp collected_body(_initial_body), do: ""

  defp html_content_type?(nil), do: false

  defp html_content_type?(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("text/html")
  end

  defp content_length_too_large?(response, max_bytes) do
    response
    |> Req.Response.get_header("content-length")
    |> Enum.any?(fn value ->
      case Integer.parse(String.trim(value)) do
        {length, ""} when length >= 0 -> length > max_bytes
        _invalid -> false
      end
    end)
  end

  defp first_header(response, name) do
    response
    |> Req.Response.get_header(name)
    |> List.first()
  end

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?(:etimedout), do: true
  defp timeout_reason?(:connect_timeout), do: true
  defp timeout_reason?(:receive_timeout), do: true
  defp timeout_reason?({:timeout, _detail}), do: true
  defp timeout_reason?({_context, reason}), do: timeout_reason?(reason)
  defp timeout_reason?(%{reason: reason}), do: timeout_reason?(reason)
  defp timeout_reason?(_reason), do: false

  defp positive_integer_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp non_negative_integer_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> raise ArgumentError, "#{key} must be a non-negative integer"
    end
  end

  defp elapsed_ms(started_at) do
    max(System.monotonic_time(:millisecond) - started_at, 0)
  end
end
