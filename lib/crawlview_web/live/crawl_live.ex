defmodule CrawlviewWeb.CrawlLive do
  @moduledoc """
  Presents one crawl as a live, reload-safe radial graph and table.

  Crawl ownership remains entirely in `Crawlview.Crawl`; this module keeps only
  form and presentation state and renders domain-provided pages and counters.
  """

  use CrawlviewWeb, :live_view

  alias Crawlview.Crawl

  # Presets exist because nobody arriving at a blank page types their own domain;
  # they look at it and leave. The first interaction has to be a click.
  #
  # They are also chosen to SHOW something. A site with no outgoing links draws a
  # single dot and teaches nothing, which rules out the reserved example.* domains
  # however tempting they are. These three are small, stable, well-behaved and
  # have real internal structure, so the shape that appears is worth looking at.
  @presets [
    {"The first website (1991)", "https://info.cern.ch/"},
    {"elixir-lang.org", "https://elixir-lang.org/"},
    {"davidhaggstrom.dev", "https://davidhaggstrom.dev/"}
  ]

  @broken_outcomes [:not_found, :client_error, :server_error, :timeout, :unreachable]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:pages, dom_id: &page_dom_id/1)
      |> stream(:pages, [])
      |> assign(
        form: crawl_form(""),
        validation_error: nil,
        crawl_notice: nil,
        crawl_id: nil,
        status: :idle,
        stats: nil,
        finished_reason: nil,
        presets: @presets
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"crawl" => id}, _uri, socket) when is_binary(id) and id != "" do
    if socket.assigns.crawl_id == id do
      {:noreply, socket}
    else
      # The opaque id lives in the query string so the single `/` screen remains
      # shareable and a remount can recover its in-memory crawl from a snapshot.
      :ok = Crawl.subscribe(id)

      case Crawl.snapshot(id) do
        {:ok, state} -> {:noreply, restore_snapshot(socket, state)}
        :not_found -> {:noreply, unavailable_crawl(socket)}
      end
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start", %{"crawl" => %{"url" => url}}, socket) do
    start_crawl(socket, url)
  end

  # Presets turn an otherwise blank first visit into a useful one-click trial;
  # the reserved example domains are intentionally tiny and stable.
  def handle_event("start_preset", %{"url" => url}, socket) do
    start_crawl(socket, url)
  end

  def handle_event("stop", _params, %{assigns: %{crawl_id: id, status: :running}} = socket) do
    :ok = Crawl.stop(id)
    {:noreply, socket}
  end

  def handle_event("stop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:page, page, stats}, socket) do
    {:noreply,
     socket
     |> assign(:stats, stats)
     |> stream_insert(:pages, page, at: 0)
     |> push_event("site_graph:node", graph_node(page))}
  end

  def handle_info({:finished, stats, reason}, socket) do
    {:noreply,
     assign(socket,
       stats: stats,
       status: :finished,
       finished_reason: reason
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="crawl-screen" class="space-y-8">
        <header class="space-y-2">
          <p class="text-sm font-semibold uppercase tracking-[0.18em] text-primary">Crawlview</p>
          <h1 class="text-3xl font-bold tracking-tight text-base-content">
            See a site as it is crawled
          </h1>
          <p class="max-w-xl text-base leading-7 text-base-content/70">
            Enter one public website. We will follow its internal links and mark broken pages as they appear.
          </p>
        </header>

        <section
          id="crawl-controls"
          class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <.form for={@form} id="crawl-form" phx-submit="start" class="space-y-3">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-end">
              <div class="min-w-0 flex-1">
                <.input
                  field={@form[:url]}
                  type="url"
                  label="Website address"
                  placeholder="https://example.com/"
                  autocomplete="url"
                  disabled={@status == :running}
                />
                <p
                  :if={@validation_error}
                  id="url-error"
                  role="alert"
                  class="mt-1 flex items-center gap-2 text-sm text-error"
                >
                  <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
                  {@validation_error}
                </p>
              </div>
              <.button
                id="start-crawl"
                variant="primary"
                disabled={@status == :running}
                class="btn btn-primary sm:mb-2"
              >
                Start crawling
              </.button>
            </div>
          </.form>

          <div id="crawl-presets" class="mt-4 flex flex-wrap items-center gap-2">
            <span class="text-sm text-base-content/60">Try an example:</span>
            <button
              :for={{label, url} <- @presets}
              id={"preset-#{String.downcase(label)}"}
              type="button"
              phx-click="start_preset"
              phx-value-url={url}
              disabled={@status == :running}
              class="btn btn-sm btn-ghost border border-base-300 transition-transform hover:-translate-y-0.5"
            >
              {label}
            </button>
          </div>
        </section>

        <p :if={@crawl_notice} id="crawl-notice" role="status" class="alert alert-warning">
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          {@crawl_notice}
        </p>

        <section :if={@crawl_id} id="crawl-results" class="space-y-5" aria-live="polite">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="text-sm text-base-content/60">Crawl</p>
              <p id="crawl-id" class="font-mono text-sm">{@crawl_id}</p>
            </div>

            <.button
              :if={@status == :running}
              id="stop-crawl"
              phx-click="stop"
              class="btn btn-error btn-soft"
            >
              <.icon name="hero-stop-circle" class="size-5" /> Stop crawl
            </.button>

            <p
              :if={@status == :finished}
              id="finished-reason"
              class="flex max-w-md items-start gap-2 text-sm font-medium"
            >
              <.icon name="hero-flag" class="mt-0.5 size-5 shrink-0" />
              {finished_sentence(@finished_reason)}
            </p>
          </div>

          <dl :if={@stats} id="crawl-stats" class="grid grid-cols-2 gap-2 sm:grid-cols-5">
            <div
              :for={{label, value} <- stat_items(@stats)}
              class="rounded-xl border border-base-300 p-3"
            >
              <dt class="text-xs font-medium uppercase tracking-wide text-base-content/55">
                {label}
              </dt>
              <dd class="mt-1 text-2xl font-semibold tabular-nums">{value}</dd>
            </div>
          </dl>

          <figure
            id="site-graph-panel"
            class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm sm:p-6"
          >
            <div class="mb-4 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <h2 class="text-lg font-semibold text-base-content">Site shape</h2>
                <p id="site-graph-description" class="text-sm text-base-content/60">
                  Distance from the centre is click depth. The table below remains the complete accessible record.
                </p>
              </div>
              <p class="text-xs font-medium text-error">
                Ringed nodes are broken pages
              </p>
            </div>
            <div
              id="site-graph"
              phx-hook="SiteGraph"
              phx-update="ignore"
              class="mx-auto w-full max-w-xl"
            >
            </div>
          </figure>

          <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
            <div class="overflow-x-auto">
              <table class="table" aria-label="Crawled pages">
                <thead class="bg-base-200/70">
                  <tr>
                    <th>Outcome</th>
                    <th>Status</th>
                    <th>Depth</th>
                    <th>Title</th>
                    <th>URL</th>
                    <th class="text-right">Time</th>
                  </tr>
                </thead>
                <tbody id="crawl-pages" phx-update="stream">
                  <tr id="pages-empty" class="hidden only:table-row">
                    <td colspan="6" class="py-10 text-center text-base-content/55">
                      Waiting for the first page…
                    </td>
                  </tr>
                  <tr
                    :for={{dom_id, page} <- @streams.pages}
                    id={dom_id}
                    data-outcome={page.outcome}
                    class={[
                      "transition-colors",
                      broken?(page.outcome) && "border-l-4 border-l-error bg-error/5"
                    ]}
                  >
                    <td>
                      <span class={outcome_class(page.outcome)}>
                        <.icon name={outcome_icon(page.outcome)} class="size-4 shrink-0" />
                        {outcome_label(page.outcome)}
                      </span>
                    </td>
                    <td class="font-mono text-xs">{status_label(page.status)}</td>
                    <td class="tabular-nums">{page.depth}</td>
                    <td class="max-w-52 truncate" title={page.title || "Untitled page"}>
                      {page.title || "Untitled page"}
                    </td>
                    <td class="max-w-80 font-mono text-xs">
                      <a
                        href={page.url}
                        target="_blank"
                        rel="noreferrer"
                        title={page.url}
                        class="link link-hover break-all"
                      >
                        {short_url(page.url)}
                      </a>
                    </td>
                    <td class="text-right font-mono text-xs tabular-nums">
                      {duration_label(page.duration_ms)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp start_crawl(%{assigns: %{status: :running}} = socket, _url), do: {:noreply, socket}

  defp start_crawl(socket, url) do
    socket = assign(socket, form: crawl_form(url), validation_error: nil, crawl_notice: nil)

    case Crawl.start(url, []) do
      {:ok, id} ->
        # start/2 cannot reveal an id before the server starts. Subscribing
        # immediately and then snapshotting closes that unavoidable event gap.
        :ok = Crawl.subscribe(id)

        socket =
          case Crawl.snapshot(id) do
            {:ok, state} -> restore_snapshot(socket, state)
            :not_found -> unavailable_crawl(socket)
          end

        {:noreply, push_patch(socket, to: ~p"/?crawl=#{id}")}

      {:error, reason} ->
        {:noreply, assign(socket, :validation_error, error_sentence(reason))}
    end
  end

  defp restore_snapshot(socket, state) do
    # The snapshot exposes pages as a map with no completion sequence. URL order
    # is deterministic after reload; live arrivals are inserted newest-first.
    pages = state.pages |> Map.values() |> Enum.sort_by(& &1.url)

    socket =
      socket
      |> assign(
        form: crawl_form(state.root_url),
        validation_error: nil,
        crawl_notice: nil,
        crawl_id: state.id,
        status: state.status,
        stats: state.stats,
        finished_reason: state.finished_reason
      )
      |> stream(:pages, pages, reset: true)
      |> push_event("site_graph:reset", %{})

    Enum.reduce(pages, socket, fn page, socket ->
      push_event(socket, "site_graph:node", graph_node(page))
    end)
  end

  defp unavailable_crawl(socket) do
    socket
    |> assign(
      crawl_id: nil,
      status: :idle,
      stats: nil,
      finished_reason: nil,
      crawl_notice:
        "That crawl is no longer available. In-memory crawls are lost when the server restarts."
    )
    |> stream(:pages, [], reset: true)
  end

  defp crawl_form(url), do: to_form(%{"url" => url}, as: :crawl)

  defp error_sentence(:invalid_scheme), do: "Use an address beginning with http:// or https://."
  defp error_sentence(:invalid_url), do: "Enter a complete, valid website address."
  defp error_sentence(:unresolvable), do: "That address did not resolve."

  defp error_sentence(:private_address),
    do: "That address points to a private or reserved network."

  defp error_sentence(_reason), do: "That address cannot be crawled."

  # Deliberately does not name a number. The page limit is an option that callers
  # can set and that the server then clamps, so any figure written here would be
  # a lie for every crawl that did not use the default.
  defp finished_sentence(:page_limit), do: "The crawl stopped at its page limit."
  defp finished_sentence(:time_limit), do: "The crawl ran out of its time budget."
  defp finished_sentence(:disallowed), do: "The site's robots.txt asked us not to crawl it."
  defp finished_sentence(:stopped), do: "You stopped the crawl. Pages already visited are kept."

  defp finished_sentence(:completed),
    do: "There was nothing left to visit, so the crawl completed normally."

  defp finished_sentence(_reason), do: "The crawl ended."

  defp stat_items(stats) do
    [
      {"Visited", stats.visited},
      {"Queued", stats.queued},
      {"In flight", stats.in_flight},
      {"OK", stats.ok},
      {"Broken", stats.broken}
    ]
  end

  defp broken?(outcome), do: outcome in @broken_outcomes

  defp graph_node(page) do
    %{
      url: page.url,
      depth: page.depth,
      referrer: page.referrer,
      outcome: page.outcome
    }
  end

  defp outcome_class(outcome) do
    [
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-1 text-xs font-semibold",
      if(broken?(outcome),
        do: "bg-error/15 text-error",
        else: "bg-success/15 text-success"
      )
    ]
  end

  defp outcome_icon(outcome) do
    if broken?(outcome), do: "hero-exclamation-triangle", else: "hero-check-circle"
  end

  defp outcome_label(:ok), do: "Good"
  defp outcome_label(:redirect), do: "Redirect"
  defp outcome_label(:not_found), do: "Broken · not found"
  defp outcome_label(:client_error), do: "Broken · client error"
  defp outcome_label(:server_error), do: "Broken · server error"
  defp outcome_label(:timeout), do: "Broken · timed out"
  defp outcome_label(:unreachable), do: "Broken · unreachable"
  defp outcome_label(:not_html), do: "Not HTML"
  defp outcome_label(:too_large), do: "Too large"
  defp outcome_label(outcome), do: outcome |> to_string() |> String.replace("_", " ")

  defp status_label(nil), do: "—"
  defp status_label(status), do: Integer.to_string(status)

  defp duration_label(milliseconds) when milliseconds < 1_000, do: "#{milliseconds} ms"

  defp duration_label(milliseconds),
    do: :erlang.float_to_binary(milliseconds / 1_000, decimals: 1) <> " s"

  defp short_url(url) when byte_size(url) <= 84, do: url
  defp short_url(url), do: String.slice(url, 0, 81) <> "…"

  defp page_dom_id(page) do
    digest = :crypto.hash(:sha256, page.url) |> Base.url_encode64(padding: false)
    "page-#{digest}"
  end
end
