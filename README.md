# Crawlview

Give it a URL. It crawls that one site and draws the map as it goes, marking broken links as it
finds them.

It is not an SEO suite and not a general web crawler. One site, one visit, one picture.

## Why a picture instead of a table

Tools in this space hand you a table when they finish. A table is good for looking something up,
but it does not show you the shape of a site: how deep it goes, which branches are thin, where the
dead ends are. Those are easier to see than to read.

The crawl streams, so you watch it rather than wait for it. You can stop it halfway and keep what
it already found. The table is still there, under the picture, for when you want the record.

## Running it

```bash
mix setup
mix phx.server
```

Then open http://localhost:4000.

Built and tested on Elixir 1.20 and OTP 29; `mix.exs` accepts 1.17 and later. There is no database
to set up.

## JSON API

The screen and the API are two renderings of the same snapshot.

```
POST   /api/crawls            {"url": "https://example.com/"}   -> 201 {"id": "..."}
GET    /api/crawls/:id                                          -> 200 crawl + stats
GET    /api/crawls/:id/pages?offset=0&limit=100                 -> 200 pages + pagination
DELETE /api/crawls/:id                                          -> 204, idempotent
```

```bash
curl -X POST localhost:4000/api/crawls \
  -H 'content-type: application/json' \
  -d '{"url":"https://info.cern.ch/","max_pages":12}'
```

## How it works

One GenServer per crawl, and it is the only thing that writes crawl state. Fetches run in
supervised tasks that are monitored but not linked, so a page that blows up costs you that page
and nothing else.

Around it are four modules that know nothing about each other. `Fetcher` turns a URL into bytes and
never raises. `Extractor` reads HTML. `Url` decides what counts as a visitable URL. `Robots` holds
the site's policy. `Crawl.Frontier` decides what to start next and when, and it takes the current
time as an argument, which is what makes the pacing testable without running a crawl.

The whole public interface of the crawler is `start/2`, `subscribe/1`, `snapshot/1` and `stop/1`.
The LiveView and the JSON API are both clients of exactly that. The reasoning behind the module
boundaries is in [DESIGN.md](DESIGN.md).

## Politeness

Requests start at most one every 350 ms, and a site's own `Crawl-delay` wins whenever it asks for
more room. That interval is what sets the pace. The limit of three requests in flight per host is
not a throttle: it is there so one page taking its full timeout does not freeze the picture for
whoever is watching.

A missing `robots.txt` is not an error. It means allowed.

## What it does not do

- **No database.** A crawl lives in memory and dies with the process. Reloading the browser
  recovers it through the id in the URL; restarting the server does not.
- **It cannot find orphan pages.** Nothing links to them, and this follows links.
- **Small budgets:** 200 pages, depth 5, two minutes. The server clamps these, so a client cannot
  ask for more than the server allows.
- **`http` and `https` stay separate.** They can serve different bytes, and a redirect between them
  is worth seeing.

## Security

The URL you type is the only untrusted input, and it is checked once: http or https, it has to
resolve, and it is rejected if it resolves to a loopback, private, link-local, carrier-NAT,
multicast or reserved address, including IPv4-mapped IPv6.

After that, same site means the same host, exactly. `www.example.com` is not `example.com` here,
because treating them as one site would let a page introduce a name nobody resolved. The one case
where a crawl adopts a host it was not given is a root that redirects to another name for itself,
and that name goes through the same check first. `robots.txt` is fetched through the same path as
every page, and its redirects are followed only while the host stays the same.

DNS rebinding is out of scope, and says so in the code.

## Tests

```bash
mix test
```

The tests stub HTTP, so none of them reach the internet. CI also runs `mix format --check-formatted`,
`mix credo --strict` and `mix dialyzer`.
