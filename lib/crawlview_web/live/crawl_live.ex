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
  # Each preset names the KIND of site and lets the address speak for itself. A name
  # that repeats the host makes the label and the example do the same job twice.
  @presets [
    {"The first website, 1991", "https://info.cern.ch/"},
    {"A language's documentation", "https://elixir-lang.org/"},
    {"A personal blog", "https://davidhaggstrom.dev/"}
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
        root_url: nil,
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

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       form: crawl_form(""),
       validation_error: nil,
       crawl_notice: nil,
       crawl_id: nil,
       root_url: nil,
       status: :idle,
       stats: nil,
       finished_reason: nil
     )
     |> stream(:pages, [], reset: true)}
  end

  @impl true
  def handle_event("start", %{"crawl" => %{"url" => url}}, socket) do
    start_crawl(socket, url)
  end

  def handle_event("start_preset", %{"url" => url}, socket) do
    start_crawl(socket, url)
  end

  def handle_event("stop", _params, %{assigns: %{crawl_id: id, status: :running}} = socket) do
    :ok = Crawl.stop(id)
    {:noreply, socket}
  end

  def handle_event("stop", _params, socket), do: {:noreply, socket}

  # Returning to the field is a navigation, not a mutation: the finished crawl stays
  # readable at its own address, so leaving it must not stop or discard it.
  def handle_event("reset", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/")}
  end

  @impl true
  def handle_info({:page, page, stats}, socket) do
    {:noreply,
     socket
     |> assign(:stats, stats)
     # The depth-0 page IS the crawl's root, so it settles the host without needing a
     # third kind of event. It matters because start/2 returns before the root is even
     # fetched: a site that answers under another name (apex to www, or http to https)
     # only reveals its real address once that first request comes back.
     |> then(fn socket ->
       if page.depth == 0, do: assign(socket, :root_url, page.url), else: socket
     end)
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
      <div id="crawl-screen">
        <%!-- IDLE: the field is the hero. Nothing competes with it. --%>
        <section :if={@status == :idle} id="station" class="station">
          <h1 class="station__title">Every site has a shape.</h1>
          <p class="station__lede">
            Paste an address. We follow its internal links and plot what we find, marking
            the broken ones as they turn up.
          </p>

          <.form for={@form} id="crawl-form" phx-submit="start" class="station__form">
            <label for="crawl_url" class="field__label">Website address</label>
            <div class="field">
              <input
                type="url"
                name="crawl[url]"
                id="crawl_url"
                value={@form[:url].value}
                placeholder="https://example.com"
                autocomplete="url"
                spellcheck="false"
                class="field__input"
              />
              <button id="start-crawl" type="submit" class="field__submit">Start crawling</button>
            </div>
            <p :if={@validation_error} id="url-error" role="alert" class="field__error">
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
              {@validation_error}
            </p>
          </.form>

          <div id="crawl-presets" class="presets">
            <span class="presets__label">Or try one of these</span>
            <div class="presets__list">
              <button
                :for={{label, url} <- @presets}
                id={"preset-#{String.downcase(label)}"}
                type="button"
                phx-click="start_preset"
                phx-value-url={url}
                class="preset"
              >
                <span class="preset__name">{label}</span>
                <span class="preset__host">{host_of(url)}</span>
              </button>
            </div>
          </div>

          <p :if={@crawl_notice} id="crawl-notice" role="status" class="notice">
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            {@crawl_notice}
          </p>
        </section>

        <%!-- ACTIVE: the chrome recedes to a bar and the plot takes the canvas. --%>
        <section :if={@crawl_id} id="crawl-results" aria-live="polite">
          <div id="station-bar" class="bar">
            <div class="bar__identity">
              <span class="bar__host">{host_of(@root_url)}</span>
              <span id="crawl-id" class="bar__id">{@crawl_id}</span>
            </div>

            <dl :if={@stats} id="crawl-stats" class="readout">
              <div :for={{label, value, tone} <- stat_items(@stats)} class={["readout__cell", tone]}>
                <dt class="readout__label">{label}</dt>
                <dd class="readout__value">{value}</dd>
              </div>
            </dl>

            <div class="bar__actions">
              <span :if={@status == :running} class="pulse" aria-hidden="true"></span>
              <button
                :if={@status == :running}
                id="stop-crawl"
                type="button"
                phx-click="stop"
                class="action action--stop"
              >
                Stop crawling
              </button>
              <button
                :if={@status == :finished}
                id="new-crawl"
                type="button"
                phx-click="reset"
                class="action"
              >
                New crawl
              </button>
            </div>
          </div>

          <p :if={@status == :finished} id="finished-reason" class="outcome-line">
            {finished_sentence(@finished_reason)}
          </p>

          <figure id="site-graph-panel" class="plot">
            <figcaption class="plot__caption">
              <h2 class="plot__title">Site shape</h2>
              <p id="site-graph-description" class="plot__note">
                Rings are clicks from the front page. The table below is the full record.
              </p>
            </figcaption>
            <%!-- The hook owns the plot AND its key: it already holds every node, so the
                  per-depth tally is computed there rather than mirrored on the server. --%>
            <div id="site-graph" phx-hook="SiteGraph" phx-update="ignore" class="plot__canvas"></div>
          </figure>

          <div class="record">
            <table class="record__table" aria-label="Crawled pages">
              <thead>
                <tr>
                  <th class="col-status">Status</th>
                  <th class="col-path">Path</th>
                  <th class="col-depth">Depth</th>
                  <th class="col-title">Title</th>
                  <th class="col-time">Time</th>
                </tr>
              </thead>
              <tbody id="crawl-pages" phx-update="stream">
                <tr id="pages-empty" class="record__empty only:table-row hidden">
                  <td colspan="5">The first page will appear here.</td>
                </tr>
                <tr
                  :for={{dom_id, page} <- @streams.pages}
                  id={dom_id}
                  data-url={page.url}
                  data-outcome={page.outcome}
                  data-broken={to_string(broken?(page.outcome))}
                  class="record__row"
                >
                  <td class="col-status">
                    <span class="verdict">
                      <span class="verdict__code">{status_label(page.status)}</span>
                      <span class="verdict__word">{outcome_label(page.outcome)}</span>
                    </span>
                  </td>
                  <td class="col-path">
                    <a href={page.url} target="_blank" rel="noreferrer" title={page.url} class="path">
                      {path_of(page.url, @root_url)}
                    </a>
                  </td>
                  <td class="col-depth">
                    <span class="depth-chip" style={"--depth-step: #{page.depth}"}>
                      {page.depth}
                    </span>
                  </td>
                  <td class="col-title" title={page.title || "Untitled"}>
                    {page.title || "Untitled"}
                  </td>
                  <td class="col-time">{duration_label(page.duration_ms)}</td>
                </tr>
              </tbody>
            </table>
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
        root_url: state.root_url,
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
      root_url: nil,
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
      {"Visited", stats.visited, nil},
      {"Queued", stats.queued, nil},
      {"In flight", stats.in_flight, nil},
      {"OK", stats.ok, "is-ok"},
      {"Broken", stats.broken, ["is-broken", stats.broken > 0 && "has-any"]}
    ]
  end

  defp broken?(outcome), do: outcome in @broken_outcomes

  defp graph_node(page) do
    %{
      url: page.url,
      depth: page.depth,
      referrer: page.referrer,
      outcome: page.outcome,
      # The words belong to the server, which already owns them for the table. Sending
      # the label as well as the atom keeps the plot and the record saying the same
      # thing about the same page, instead of one of them showing `not_found`.
      outcome_label: outcome_label(page.outcome),
      status: page.status,
      title: page.title
    }
  end

  defp outcome_label(:ok), do: "OK"
  defp outcome_label(:redirect), do: "Redirect"
  defp outcome_label(:not_found), do: "Not found"
  defp outcome_label(:client_error), do: "Client error"
  defp outcome_label(:server_error), do: "Server error"
  defp outcome_label(:timeout), do: "Timed out"
  defp outcome_label(:unreachable), do: "Unreachable"
  defp outcome_label(:not_html), do: "Not HTML"
  defp outcome_label(:too_large), do: "Too large"
  defp outcome_label(outcome), do: outcome |> to_string() |> String.replace("_", " ")

  defp status_label(nil), do: "—"
  defp status_label(status), do: Integer.to_string(status)

  defp duration_label(milliseconds) when milliseconds < 1_000, do: "#{milliseconds} ms"

  defp duration_label(milliseconds),
    do: :erlang.float_to_binary(milliseconds / 1_000, decimals: 1) <> " s"

  defp host_of(nil), do: ""

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _unparsed -> url
    end
  end

  # The host is constant for a whole crawl and is already stated once in the bar, so
  # repeating it on every row would spend the widest column on the one thing that
  # never varies. Rows show what actually differs: the path.
  defp path_of(url, root_url) do
    uri = URI.parse(url)
    same_host? = is_binary(root_url) and uri.host == URI.parse(root_url).host

    cond do
      not same_host? -> url
      uri.query -> (uri.path || "/") <> "?" <> uri.query
      true -> uri.path || "/"
    end
  end

  defp page_dom_id(page) do
    digest = :crypto.hash(:sha256, page.url) |> Base.url_encode64(padding: false)
    "page-#{digest}"
  end
end
