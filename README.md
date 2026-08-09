# Crawlview

Give it a URL. Watch the site draw itself while it gets crawled, with broken links marked as
they are found.

Not an SEO suite and not a general web crawler. One site, one visit, one picture.

## Why it looks like this

Every tool in this space hands you a table when it finishes. You wait, and then you read rows.
The interesting thing about a website is not its rows, it is its **shape**: how deep it goes,
which branches are thin, where the dead ends hang. A red node dangling off a branch tells you
more in one second than row 340 of a CSV.

So the crawl is something you watch rather than something you wait for. It streams, you can stop
it mid-flight without losing what it already found, and the output is a picture with a table
underneath it for when you need the record instead of the glance.

## Running it

```bash
mix setup
mix phx.server
# http://localhost:4000
```

Requires Elixir 1.17+ and Erlang/OTP 27+. No database: see the deliberate limits below.

## The JSON API

The screen and the API are two renderings of the same snapshot, not two implementations.

```
POST   /api/crawls            {"url": "https://example.com/"}   -> 201 {"id": "..."}
GET    /api/crawls/:id                                          -> 200 crawl + stats
GET    /api/crawls/:id/pages?offset=0&limit=100                  -> 200 pages + pagination
DELETE /api/crawls/:id                                          -> 204 (idempotent)
```

```bash
curl -X POST localhost:4000/api/crawls \
  -H 'content-type: application/json' \
  -d '{"url":"https://info.cern.ch/","max_pages":12}'
```

## How it is built

The design contract lives in [DESIGN.md](DESIGN.md) and it is the interesting document in this
repo. The short version:

```
Crawlview.Crawl        the deep module: four public functions, eight concerns hidden
  ├─ Crawl.Server      one GenServer per crawl. THE single writer.
  ├─ Crawl.Frontier    pure: what to start next, and when. Its clock is an argument.
  └─ workers           supervised, monitored, NOT linked. A crash loses one page.

Crawlview.Fetcher      HTTP: url in, bytes out. Total function: never raises, never errors.
Crawlview.Extractor    pure: HTML in, title + hrefs out.
Crawlview.Url          pure: what counts as a visitable URL, and the canonical form of one.
Crawlview.Robots       a crawl-scoped policy value. Not a process.
```

Dependencies point one way. The leaf modules know nothing about each other and nothing about
crawling, with one exception written down on purpose: `Robots` fetches through `Fetcher`, because
one module speaks HTTP and the alternative was a second one quietly opening its own connections.
`Crawl` is the pipe that joins them. Nothing depends on `Crawl` except the web layer,
and the web layer can only reach it through those four functions.

The whole public interface of the crawler is:

```elixir
Crawl.start(url, opts)   # {:ok, id} | {:error, reason}
Crawl.subscribe(id)      # then you receive {:page, page, stats} and one {:finished, stats, reason}
Crawl.snapshot(id)       # {:ok, state} | :not_found
Crawl.stop(id)           # :ok, always
```

The LiveView and the JSON API are both thin clients of exactly that. Neither holds a second copy
of crawl state, which is why the `{:page, ...}` event carries the stats along with the page: no
consumer should ever have to mirror the domain to render a counter.

### Why Elixir is not decoration here

A crawler is concurrency with a name: many fetches at once, each able to fail on its own, each a
guest on someone else's server. The parts of this that are pleasant in Elixir and miserable
elsewhere:

- One supervised process tree per crawl. A crawl is a thing you can start, watch and kill.
- Workers are monitored but **not linked**, so a page that blows up cannot take the crawl with it.
- One writer owns all mutable state, so there are no races to reason about anywhere else.
- The live screen is server-pushed state, which is LiveView's actual reason to exist rather than
  a websocket layer bolted onto a SPA.

### Politeness is the throttle

There are several limits and it is worth knowing which one actually binds, because it is not the
one people assume. A minimum interval of 350 ms gates request **starts**, so the rate is one per
interval no matter how many requests are allowed in flight. The per-host limit of 3 is not a
throttle at all: it exists so that one page that takes its full ten-second timeout cannot freeze
the picture of a crawl somebody is watching. How fast we go is decided by courtesy to the one
server we are visiting, not by how much parallelism the machine could afford.

`robots.txt` is respected, including `Crawl-delay`. A missing `robots.txt` is not an error, it is
permission.

### The security gate, in one place

The URL you type is the only untrusted input, and it is validated exactly once, by
`Url.public_http_url/1`: http(s) only, must resolve, and rejected if it resolves to a loopback,
link-local, private, carrier-NAT, multicast or reserved address, including IPv4-mapped IPv6
addresses. Same-site then means the **same host, exactly**: `www.example.com` is not
`example.com` here, because treating them as one site would let a page smuggle in a name that
nobody resolved. The one case where a crawl adopts a host it was not given is a root that
redirects to another name for itself, and that name goes through the same gate before it is
adopted. `robots.txt` is fetched through the same hardened path as every page, and its redirects
are followed only while the host does not change.

DNS rebinding is knowingly out of scope, and said so in the code rather than left for you to
wonder about.

## Deliberate limits

These are decisions, not things left undone. A limit you can explain is judgement; a limit you
hide is a defect.

- **No database.** Crawls live in memory and die with the process. A browser reload recovers a
  crawl through its id in the URL; a server restart does not. The gain is that the whole system
  is one deployable with no state to manage, which is the right trade for a tool whose output is
  interesting for about a minute.
- **Orphan pages are out of scope.** A crawler that follows links cannot, by construction, find
  pages that nothing links to. Saying so is more honest than a feature that half works.
- **One site at a time, small budgets.** 200 pages, depth 5, a two-minute ceiling, all clamped
  server-side so a hostile client cannot ask for the moon.
- **`http` and `https` are not merged.** They can genuinely serve different bytes, and a redirect
  between them is information worth recording rather than hiding.

## Tests

```bash
mix test
```

The interesting ones are `test/crawlview/crawl_test.exs`, which drives the deep module through
its four public functions only, and `test/crawlview/url_test.exs`, which pins down the invariant
the whole crawl rests on: two URLs that fetch the same bytes must normalize to the same string,
because that string is the deduplication key.

No test touches the network.
