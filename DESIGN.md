# Crawlview: design contract

This document is the **single source of truth for module boundaries**. Every agent working on
this repo reads it first and implements against it without renegotiating it. If you believe a
contract here is wrong, say so in your report; do not silently change it.

## What the product is

You give it a URL. It crawls that one site, politely and concurrently, and you watch the site's
shape draw itself on screen while it happens, with broken links marked as they are found.

Not a general web crawler. Not an SEO suite. One site, one visit, one picture.

## Design philosophy (non-negotiable)

We follow **John Ousterhout, _A Philosophy of Software Design_**, and the **UNIX philosophy**.
Concretely, in this repo that means:

1. **Deep modules.** A module's interface must be much smaller than its implementation.
   `Crawlview.Crawl` has four public functions and hides eight concerns behind them.
2. **Information hiding.** The frontier data structure, the concurrency mechanism, the retry
   policy and the politeness scheme are invisible outside the module that owns them. If a caller
   has to know, the boundary is wrong.
3. **Define errors out of existence.** Prefer interfaces where the failure case simply cannot be
   expressed. A page that 404s is not an error, it is a result. A missing `robots.txt` is not an
   error, it is a permissive policy. Do not invent `{:error, _}` tuples for situations the caller
   has no distinct action for.
4. **No shallow layers, no pass-through methods.** A function that only forwards to another
   function adds a name and no abstraction. Delete it. In particular: no Phoenix "context"
   wrapper around `Crawlview.Crawl`. `Crawlview.Crawl` *is* the context.
5. **General-purpose interfaces over special-purpose ones.** The crawler must not know that a
   web UI exists. It publishes domain events; LiveView, the JSON API and the test suite are all
   equal consumers of the same stream.
6. **Different layer, different abstraction.** If two adjacent layers have the same shape, one of
   them is redundant.
7. **UNIX philosophy: one thing, done well, composable.** `Fetcher` gets bytes. `Extractor` reads
   HTML. `Url` decides what is visitable. `Robots` decides what is permitted. None of them knows
   about the others. `Crawl` is the pipe that joins them.
8. **Comments carry what the code cannot**: invariants, units, why. Not restatements of the code.

## Module map

```
Crawlview.Crawl        deep module, the only public entry point   (stateful, OTP)
  ├─ Crawl.Supervisor  DynamicSupervisor, one child tree per crawl
  ├─ Crawl.Server      GenServer: owns frontier + results. SINGLE WRITER.
  └─ Crawl.Worker      Task: fetch one URL, hand result back. Crash-isolated.

Crawlview.Fetcher      HTTP: URL in, bytes out. Never raises, never errors.
Crawlview.Extractor    pure: HTML in, title + hrefs out.
Crawlview.Url          pure: what is a visitable URL for this crawl.
Crawlview.Robots       crawl-scoped robots.txt policy value.
Crawlview.Page         struct: one visited URL and everything known about it.
Crawlview.Stats        struct: counters for one crawl.
```

Dependencies point one way only: `Crawl` → {`Fetcher`, `Extractor`, `Url`, `Robots`}. The leaves
depend on nothing of ours. There is **no** module that depends on `Crawl` other than the web layer.

## Contracts

### `Crawlview.Url` (pure, no network except where stated)

```elixir
@spec visitable([String.t()], base :: String.t(), root :: String.t()) :: [String.t()]
```

Takes the raw `href` values from one page and returns the normalized, absolute, deduplicated,
same-site URLs worth visiting, in document order. Everything else is silently absent from the
result: `mailto:`, `tel:`, `javascript:`, other hosts, other schemes, fragments-only links,
malformed values. **There is no error return and no rejection reason.** A caller cannot forget a
check because there is no check to remember.

Normalization: resolve against `base`, drop the fragment, lowercase scheme and host, drop default
ports, sort query parameters, treat `/path` and `/path/` as the same URL, drop `index.html`.
Two URLs that fetch the same bytes must normalize to the same string, because this string is the
deduplication key for the whole crawl.

```elixir
@spec public_http_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
```

The **one** function here that does I/O (DNS) and the **one** that returns errors, because it
validates human input and the human needs to be told why. Used exactly once per crawl, on the URL
typed into the form. Rejects: non-http(s) schemes, hosts that do not resolve, and any host
resolving to a loopback, link-local, private or reserved address.

> Why this closes SSRF for the whole system: the root is validated once here, and `visitable/3`
> only ever yields same-site URLs. So no crawl can reach an address the root did not already
> resolve to. Note in a comment that DNS rebinding is knowingly out of scope.

### `Crawlview.Extractor` (pure)

```elixir
@spec extract(html :: binary()) :: %{title: String.t() | nil, hrefs: [String.t()]}
```

Never raises. Malformed HTML yields best-effort results, not an exception. Knows nothing about
URLs, sites or crawling: it reads a document and reports what it says.

### `Crawlview.Fetcher`

```elixir
@spec fetch(url :: String.t(), opts :: keyword()) :: %Crawlview.Fetcher.Result{}

%Crawlview.Fetcher.Result{
  outcome:      :ok | :redirect | :not_found | :client_error | :server_error
              | :timeout | :unreachable | :not_html | :too_large,
  status:       pos_integer() | nil,   # nil when no HTTP response was received at all
  content_type: String.t() | nil,
  redirect_to:  String.t() | nil,      # absolute, when outcome == :redirect
  body:         binary() | nil,        # nil unless outcome == :ok and body is HTML
  duration_ms:  non_neg_integer()
}
```

**This function never raises and never returns an error tuple.** A refused connection, a DNS
failure, a TLS error, a timeout and a 500 all produce a `Result`. The caller has exactly one
code path. This is the clearest application of "define errors out of existence" in the repo and
it is the reason the crawl loop has no error handling at all.

Does not follow redirects itself (it reports them; the crawl decides). Caps body size. Sends a
`User-Agent` identifying the tool with the project URL. Fetches only HTML: bails on other
content types after headers where possible.

### `Crawlview.Robots`

```elixir
@spec load(root_url :: String.t()) :: t()          # never fails: no robots.txt => allow all
@spec allowed?(t(), url :: String.t()) :: boolean()
@spec crawl_delay(t()) :: non_neg_integer()        # milliseconds, 0 when unspecified
```

`load/1` does the single network call, once per crawl, at start. `allowed?/2` is then pure and
cheap. An opaque value, not a process: no global cache to invalidate, trivially testable.

### `Crawlview.Page` and `Crawlview.Stats` (structs)

```elixir
%Crawlview.Page{
  url:         String.t(),           # normalized; the identity of this page
  depth:       non_neg_integer(),    # 0 for the root
  referrer:    String.t() | nil,     # the page we found it on; nil for the root
  outcome:     atom(),               # from Fetcher.Result
  status:      pos_integer() | nil,
  title:       String.t() | nil,
  links:       [String.t()],         # normalized same-site links found on this page
  duration_ms: non_neg_integer()
}

%Crawlview.Stats{
  visited: non_neg_integer(), queued: non_neg_integer(), in_flight: non_neg_integer(),
  ok: non_neg_integer(), broken: non_neg_integer(),
  started_at: DateTime.t(), finished_at: DateTime.t() | nil
}
```

`referrer` + `depth` are what let the UI draw a tree without any layout state on the server.
`broken` counts outcomes in `[:not_found, :client_error, :server_error, :timeout, :unreachable]`.

### `Crawlview.Crawl` (the deep module)

```elixir
@spec start(url :: String.t(), opts :: keyword()) :: {:ok, id :: String.t()} | {:error, atom()}
@spec subscribe(id :: String.t()) :: :ok
@spec snapshot(id :: String.t()) :: {:ok, %Crawlview.Crawl.State{}} | :not_found
@spec stop(id :: String.t()) :: :ok
```

That is the entire interface. `{:error, _}` from `start/2` only ever reflects invalid human input
(it is `Url.public_http_url/1` speaking). `stop/1` on an unknown or already-finished crawl is
`:ok`, because "make sure this is not running" has no failure mode worth a caller's attention.

Options, all with defaults, all clamped server-side so a hostile client cannot ask for the moon:
`max_pages` (200), `max_depth` (5), `concurrency` (8), `per_host` (2), `timeout_ms` (10_000),
`budget_ms` (120_000).

```elixir
%Crawlview.Crawl.State{
  id:, root_url:, status: :running | :finished,
  pages: %{String.t() => %Crawlview.Page{}},
  stats: %Crawlview.Stats{},
  finished_reason: nil | :completed | :stopped | :page_limit | :time_limit
}
```

**Events**, broadcast on Phoenix.PubSub topic `"crawl:" <> id`:

```elixir
{:page, %Crawlview.Page{}, %Crawlview.Stats{}}
{:finished, %Crawlview.Stats{}, reason :: atom()}
```

Two messages, domain-shaped, with no trace of a UI in them. Stats travel with the event so no
consumer has to recompute or mirror crawl state to show a counter.

Invariants the `Server` must maintain, and must state in comments:

- Single writer: only the `Server` process mutates crawl state.
- A URL enters `pages` at most once; the frontier never contains a visited URL.
- At most `per_host` requests in flight to one host, at most `concurrency` overall.
- A crashing worker loses one page, never the crawl.
- `stop/1` keeps everything already crawled; it stops adding, it does not roll back.
- The crawl terminates on: empty frontier, `max_pages`, `budget_ms`, or `stop/1`. Always exactly
  one `{:finished, _, _}` per crawl.

### Web layer

`CrawlviewWeb` is a **thin client** of `Crawlview.Crawl`. It holds view state only (selected node,
active filter, form input). It never holds a second copy of crawl state, and it never reaches past
`Crawlview.Crawl` into `Crawl.Server` or the registry.

- LiveView at `/`: form, live table/graph, stop button, preset example sites.
- JSON API: `GET /api/crawls/:id` and `GET /api/crawls/:id/pages`, both rendering a snapshot.

The API and the LiveView must be two renderings of the same snapshot, not two implementations.

## Deliberate limits (write these in the README, do not hide them)

- **No database.** Crawls live in memory and die with the process. Reloading loses a crawl.
  Chosen so the whole system is one deployable with no state to manage.
- **Orphan pages are out of scope.** A crawler that follows links cannot, by construction, find
  pages nothing links to. Saying so is more honest than a feature that half works.
- **One site at a time, small budgets.** This is a demo running on a small box, and it is a guest
  on other people's servers.

## Rules for agents working here

- Implement **only** the files your task names. Do not touch `mix.exs`, `DESIGN.md` or another
  agent's modules. Dependencies are already installed: `req` for HTTP, `floki` for HTML.
- Every module gets `@moduledoc`, `@spec` on public functions, and ExUnit tests. Tests must not
  hit the network: pass a stub, use `Req.Test`, or serve from a fixture.
- `mix precommit` (compile with warnings as errors, format, test) must pass before you report done.
- Do not commit. Report what you did and let the orchestrator verify and commit.
- Delegate the actual writing of code to `codex exec` in small, well-scoped chunks, and review
  what comes back against this document before accepting it.
