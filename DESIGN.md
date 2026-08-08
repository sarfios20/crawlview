# Crawlview: design contract

This document is the **single source of truth for module boundaries**, and it was written before
the code. Anything here can be argued with, but not quietly: if a contract turns out to be wrong,
the contract gets changed on purpose and the reason gets written down.

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

Normalization is deliberately **conservative**: resolve against `base`, drop the fragment,
lowercase scheme and host, drop default ports, sort query parameters. That is all, and the
omissions matter. `/path` and `/path/` are NOT merged, and `index.html` is NOT dropped, because
servers routinely treat those as different resources and redirect between them.

The invariant cuts both ways, and the second half is the dangerous one. Two URLs that fetch the
same bytes must produce the same key, or a page gets crawled twice. But two URLs that fetch
DIFFERENT things must never collapse: merging `/a` with `/a/` makes a redirect target identical to
its own source, so the crawl discards it as already-visited and silently stops going deeper. A
rule that is only usually true is not a normalization, it is a guess.

Same-site means the **same host, exactly**. `www.example.com` is not `example.com` here.

```elixir
@spec public_http_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
```

The **one** function here that does I/O (DNS) and the **one** that returns errors, because it
validates human input and the human needs to be told why. Used exactly once per crawl, on the URL
typed into the form. Rejects: non-http(s) schemes, hosts that do not resolve, and any host
resolving to a loopback, link-local, private or reserved address.

> Why this closes SSRF for the whole system: every URL a crawl fetches has the root's exact host,
> and that host was validated here. The one exception is a root that redirects to another name for
> itself, and that path runs the new name through this same function before adopting it. So no
> crawl reaches a host that has not passed this gate. DNS rebinding is knowingly out of scope and
> said so in a comment.

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

Totality here is absolute, including for malformed options: an unusable `timeout_ms` falls back
to its default rather than raising. That is only safe because option values are validated and
clamped exactly once, at their entry point in `Crawlview.Crawl.start/2` (see below). Validating in
both places would mean neither place owned it; validating only at the boundary keeps `Fetcher`'s
promise unqualified and keeps bad configuration from being silently absorbed deep in the system.

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

That is the entire interface. `stop/1` on an unknown or already-finished crawl is `:ok`, because
"make sure this is not running" has no failure mode worth a caller's attention.

`{:error, _}` from `start/2` means one of two things, and both are answers a caller has to relay
to a person rather than defects:

- **Invalid input**, which is `Url.public_http_url/1` speaking.
- **`:at_capacity`**, when the node already has `max_concurrent_crawls` crawls fetching. This is
  the ceiling that stops a polite crawler being used as an amplifier: every individual crawl
  behaves, so without a limit on how many there are, politeness bounds nothing. It counts crawls
  that are still FETCHING; finished ones stay readable and stop counting, because they are no
  longer spending anyone's bandwidth.

Options, all with defaults, all clamped server-side so a hostile client cannot ask for the moon:
`max_pages` (200), `max_depth` (5), `concurrency` (8), `per_host` (2), `timeout_ms` (10_000),
`budget_ms` (120_000).

```elixir
%Crawlview.Crawl.State{
  id:, root_url:, status: :running | :finished,
  pages: %{String.t() => %Crawlview.Page{}},
  stats: %Crawlview.Stats{},
  finished_reason: nil | :completed | :stopped | :page_limit | :time_limit | :disallowed
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

## Being a good neighbour, and who enforces what

Three limits, at three layers, answering three different questions. Keeping them apart is the
point: collapsing them into one number would mean none of them could be reasoned about.

| Limit | Protects | Where it lives |
|---|---|---|
| per-host in flight, and a floor between requests | the site being crawled | `Crawl.Server` |
| crawls fetching at once (`max_concurrent_crawls`) | every site, from being amplified | `Crawl.start/2` |
| crawls started per client per window | fairness between visitors | `CrawlviewWeb.ClientLimit` |

The client limit lives in the web layer and nowhere else. "Who is asking" is a transport
question; teaching the crawler about clients to solve an abuse problem would drag an HTTP concern
into the domain. And note which layer each error surfaces as: a full node is **503** because the
client did nothing wrong, while a client over its allowance is **429**. Both carry `Retry-After`,
because a refusal without a next step is just a door.

## House rules

- Every module carries `@moduledoc`, `@spec` on its public functions, and ExUnit tests.
- **No test touches the network.** Pass a stub plug, use `Req.Test`, or serve from a fixture.
- `mix precommit` runs compile with warnings as errors, then format, then the suite. It has to
  pass before anything lands.
- HTTP goes through `req` and HTML through `floki`. Neither of those choices is worth revisiting
  for a project this size.
