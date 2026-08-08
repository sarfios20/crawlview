defmodule CrawlviewWeb.CrawlController do
  @moduledoc """
  Exposes crawl lifecycle and snapshots over JSON.

  Creation and deletion are included alongside the two snapshot routes named in
  the design contract because an API must be able to own the lifecycle it reads.
  They add no domain surface: this controller remains a direct client of
  `Crawlview.Crawl`.
  """

  use CrawlviewWeb, :controller

  alias Crawlview.Crawl

  # An explicit allowlist, not laziness: turning arbitrary client strings into atoms
  # would be a memory-exhaustion vector, because atoms are never garbage collected.
  # It does mean this list is a second copy of the domain's option names, so a new
  # option has to be added here too — which is exactly how `min_interval_ms` was
  # silently ignored by the API until someone noticed.
  @crawl_options ~w(max_pages max_depth concurrency per_host min_interval_ms timeout_ms budget_ms)a
  @default_page_limit 100
  @maximum_page_limit 100

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"url" => url} = params) when is_binary(url) do
    case Crawl.start(url, crawl_options(params)) do
      {:ok, id} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/crawls/#{id}")
        |> render(:created, id: id)

      {:error, reason} ->
        render_error(conn, :unprocessable_entity, reason)
    end
  end

  def create(conn, _params), do: render_error(conn, :unprocessable_entity, :invalid_url)

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case Crawl.snapshot(id) do
      {:ok, state} -> render(conn, :show, state: state)
      :not_found -> render_error(conn, :not_found, :not_found)
    end
  end

  @spec pages(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pages(conn, %{"id" => id} = params) do
    case Crawl.snapshot(id) do
      {:ok, state} ->
        # State stores pages in an unordered map. URL order is stable across
        # requests and agrees with LiveView snapshot restoration. Pagination
        # bounds the wire response without pretending the crawl itself is capped.
        pages = state.pages |> Map.values() |> Enum.sort_by(& &1.url)
        offset = non_negative_integer(params["offset"], 0)
        limit = positive_integer(params["limit"], @default_page_limit, @maximum_page_limit)

        render(conn, :pages,
          pages: Enum.slice(pages, offset, limit),
          offset: offset,
          limit: limit,
          total: state.stats.visited
        )

      :not_found ->
        render_error(conn, :not_found, :not_found)
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    # stop/1 is idempotent: whether the crawl ran or never existed, the client's
    # requested postcondition (it is not running) holds, so both cases are 204.
    :ok = Crawl.stop(id)
    send_resp(conn, :no_content, "")
  end

  defp render_error(conn, status, reason) do
    conn
    |> put_status(status)
    |> render(:error, reason: reason)
  end

  defp crawl_options(params) do
    Enum.reduce(@crawl_options, [], fn option, options ->
      case Map.fetch(params, Atom.to_string(option)) do
        {:ok, value} -> [{option, value} | options]
        :error -> options
      end
    end)
  end

  defp non_negative_integer(value, default) do
    case parse_integer(value) do
      integer when is_integer(integer) and integer >= 0 -> integer
      _invalid -> default
    end
  end

  defp positive_integer(value, default, maximum) do
    case parse_integer(value) do
      integer when is_integer(integer) and integer > 0 -> min(integer, maximum)
      _invalid -> default
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
