defmodule Crawlview.CrawlTest do
  use ExUnit.Case, async: false

  alias Crawlview.Crawl

  @root "https://example.com/"
  @timeout 60_000

  setup do
    default_options = Req.default_options()
    example_address = {93, 184, 216, 34}
    resolver_lookup = :inet_db.res_option(:lookup)
    test_process = self()
    site_table = :ets.new(:crawl_fake_site, [:set, :public])
    Process.put(:crawl_fake_site, site_table)

    # start/2 still exercises its real public-address validation, while the Req
    # plug below keeps every HTTP request inside this test process.
    :ok = :inet_db.set_lookup([:file])
    :ok = :inet_db.add_host(example_address, [~c"example.com"])

    plug = fn conn ->
      send(test_process, {:fake_request, conn.request_path})
      await_subscription(site_table)
      [{:site, site}] = :ets.lookup(site_table, :site)
      response = Map.get(site, conn.request_path, html("Not found", 404))

      response =
        case response do
          {:hold, held_response} ->
            send(test_process, {:held_request, conn.request_path, self()})

            receive do
              :release -> held_response
            end

          immediate_response ->
            immediate_response
        end

      {status, headers, body} = response

      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn ->
          Plug.Conn.put_resp_header(conn, name, value)
        end)

      Plug.Conn.send_resp(conn, status, body)
    end

    Req.default_options(plug: plug)

    on_exit(fn ->
      Req.default_options(default_options)
      :ok = :inet_db.del_host(example_address)
      :ok = :inet_db.set_lookup(resolver_lookup)
    end)

    :ok
  end

  test "a snapshot of an id that was never started is not found" do
    assert Crawl.snapshot("never-started") == :not_found
  end

  test "an invalid root returns the URL validation error and starts no crawl" do
    assert Crawl.start("ftp://example.com/") == {:error, :invalid_scheme}
    refute_receive {:fake_request, _path}, 50
  end

  test "stopping an unknown crawl succeeds" do
    assert Crawl.stop("never-started") == :ok
  end

  test "a one-page site is visited and completes" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<title>Home</title>")
    }

    crawl = crawl(site)

    assert crawl.reason == :completed
    assert crawl.stats.visited == 1
    assert Map.has_key?(crawl.snapshot.pages, @root)
  end

  test "the root page has depth zero and no referrer" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<title>Home</title>")
    }

    crawl = crawl(site)

    assert %{depth: 0, referrer: nil} = crawl.snapshot.pages[@root]
  end

  test "a linked page records its depth and discovering page" do
    about_url = "https://example.com/about"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/about'>About</a>"),
      "/about" => html("<title>About</title>")
    }

    crawl = crawl(site)

    assert %{depth: 1, referrer: @root} = crawl.snapshot.pages[about_url]
  end

  test "a page stores its normalized same-site links" do
    guide_url = "https://example.com/guide"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" =>
        html("""
        <a href="/guide">Guide</a>
        <a href="https://EXAMPLE.com/guide#index">Guide again</a>
        <a href="/">Home</a>
        <a href="https://elsewhere.example/page">Elsewhere</a>
        """),
      "/guide" => html("<title>Guide</title>")
    }

    crawl = crawl(site)

    # Host case and fragments collapse because those are equivalences by
    # specification. A trailing slash does not, because servers disagree about it.
    assert crawl.snapshot.pages[@root].links == [guide_url, @root]
  end

  test "pages in a cycle are each crawled once" do
    page_url = "https://example.com/page"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/page'>Page</a>"),
      "/page" => html("<a href='/'>Home</a>")
    }

    crawl = crawl(site)

    assert crawl.reason == :completed
    assert crawl.stats.visited == 2
    assert Map.keys(crawl.snapshot.pages) |> MapSet.new() == MapSet.new([@root, page_url])
  end

  test "different hrefs for the same normalized URL are visited once" do
    guide_url = "https://example.com/guide?a=1&b=2"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/guide?b=2&a=1'>One</a><a href='/guide?a=1&b=2#top'>Two</a>"),
      "/guide" => html("<title>Guide</title>")
    }

    crawl = crawl(site)

    assert crawl.stats.visited == 2
    assert Map.has_key?(crawl.snapshot.pages, guide_url)
    assert crawl.snapshot.pages[@root].links == [guide_url]
  end

  test "a redirect that only adds a trailing slash is followed to the real page" do
    # The regression that made an ordinary blog uncrawlable. The server answers /a
    # with a redirect to /a/, so if those two normalize to one key the target looks
    # already-visited and the crawl silently stops at depth 1.
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/archive'>Archive</a>"),
      "/archive" => redirect("/archive/"),
      "/archive/" => html("<title>Archive</title><a href='/archive/page'>A post</a>"),
      "/archive/page" => html("<title>A post</title>")
    }

    crawl = crawl(site)

    assert crawl.reason == :completed
    assert %{outcome: :redirect, depth: 1} = crawl.snapshot.pages["https://example.com/archive"]
    assert %{outcome: :ok, depth: 2} = crawl.snapshot.pages["https://example.com/archive/"]
    assert %{outcome: :ok, depth: 3} = crawl.snapshot.pages["https://example.com/archive/page"]
  end

  test "max_pages stops at the page limit" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/one'>One</a><a href='/two'>Two</a><a href='/three'>Three</a>"),
      "/one" => html("One"),
      "/two" => html("Two"),
      "/three" => html("Three")
    }

    crawl = crawl(site, max_pages: 2)

    assert crawl.reason == :page_limit
    assert crawl.stats.visited == 2
    assert map_size(crawl.snapshot.pages) <= 2
  end

  test "a page at max_depth records links without visiting deeper pages" do
    branch_url = "https://example.com/branch"
    deeper_url = "https://example.com/deeper"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/branch'>Branch</a>"),
      "/branch" => html("<a href='/deeper'>Deeper</a>"),
      "/deeper" => html("Too deep")
    }

    crawl = crawl(site, max_depth: 1)

    assert crawl.snapshot.pages[branch_url].depth == 1
    assert crawl.snapshot.pages[branch_url].links == [deeper_url]
    refute Map.has_key?(crawl.snapshot.pages, deeper_url)
    refute_receive {:fake_request, "/deeper"}, 50
  end

  test "max_pages is clamped to the documented server maximum" do
    page_count = 2_000

    links =
      Enum.map_join(1..page_count, fn number ->
        "<a href='/pages/#{number}'>Page #{number}</a>"
      end)

    pages =
      Map.new(1..page_count, fn number ->
        {"/pages/#{number}", html("Page #{number}")}
      end)

    site =
      Map.merge(pages, %{
        "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
        "/" => html(links)
      })

    crawl = crawl(site, max_pages: 10_000_000, concurrency: 32, per_host: 8)

    assert crawl.reason == :page_limit
    assert crawl.stats.visited == 2_000
    assert map_size(crawl.snapshot.pages) == 2_000
  end

  test "a 404 is broken while successful pages are ok" do
    missing_url = "https://example.com/missing"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/missing'>Missing</a>"),
      "/missing" => html("Missing", 404)
    }

    crawl = crawl(site)

    assert %{outcome: :not_found, status: 404} = crawl.snapshot.pages[missing_url]
    assert crawl.stats.ok == 1
    assert crawl.stats.broken == 1
  end

  test "a 500 is recorded as a broken server error" do
    failing_url = "https://example.com/failing"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/failing'>Failing</a>"),
      "/failing" => html("Failure", 500)
    }

    crawl = crawl(site)

    assert %{outcome: :server_error, status: 500} = crawl.snapshot.pages[failing_url]
    assert crawl.stats.broken == 1
  end

  test "a non-HTML response is recorded without links" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => response(200, "application/pdf", "<a href='/hidden'>Hidden</a>"),
      "/hidden" => html("Hidden")
    }

    crawl = crawl(site)

    assert %{outcome: :not_html, status: 200, links: []} = crawl.snapshot.pages[@root]
    assert crawl.stats.visited == 1
  end

  test "a redirect is recorded and its target is crawled as a discovery" do
    destination_url = "https://example.com/destination"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => redirect("/destination"),
      "/destination" => html("<title>Destination</title>")
    }

    crawl = crawl(site)

    assert %{outcome: :redirect, status: 302, links: [^destination_url]} =
             crawl.snapshot.pages[@root]

    assert %{outcome: :ok, depth: 1, referrer: @root} =
             crawl.snapshot.pages[destination_url]
  end

  test "subscribers receive one page event per visit and exactly one finish" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/one'>One</a><a href='/two'>Two</a>"),
      "/one" => html("One"),
      "/two" => html("Two")
    }

    crawl = crawl(site)

    page_events = receive_page_events(crawl.stats.visited)

    assert length(page_events) == crawl.stats.visited

    assert page_events |> Enum.map(& &1.url) |> MapSet.new() ==
             Map.keys(crawl.snapshot.pages) |> MapSet.new()

    refute_receive {:page, _, _}, 50
    refute_receive {:finished, _, _}, 100
  end

  test "page event stats agree with the finished snapshot" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<title>Home</title>")
    }

    crawl = crawl(site)
    assert_receive {:page, _page, event_stats}

    assert event_stats == %{crawl.snapshot.stats | finished_at: nil}
  end

  test "robots disallowing the root finishes without visiting a page" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nDisallow: /"),
      "/" => html("Home")
    }

    crawl = crawl(site)

    assert crawl.reason == :disallowed
    assert crawl.stats.visited == 0
    assert crawl.snapshot.pages == %{}
  end

  test "subscribers receive exactly one finished event" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nDisallow: /"),
      "/" => html("Home")
    }

    crawl = crawl(site)

    assert crawl.reason == :disallowed
    refute_receive {:finished, _, _}, 100
  end

  test "stopping a running crawl finishes it as stopped" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("Home")
    }

    configure_site(site)
    {:ok, id} = Crawl.start(@root)
    :ok = Crawl.subscribe(id)
    release_site()

    assert Crawl.stop(id) == :ok
    {stats, reason} = await_finished()
    {:ok, snapshot} = Crawl.snapshot(id)

    assert reason == :stopped
    assert stats.visited == 0
    assert snapshot.pages == %{}
  end

  test "stopping keeps pages crawled before an in-flight request is cancelled" do
    held_url = "https://example.com/held"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nAllow: /"),
      "/" => html("<a href='/held'>Held</a>"),
      "/held" => {:hold, html("Held")}
    }

    configure_site(site)
    {:ok, id} = Crawl.start(@root, per_host: 1)
    :ok = Crawl.subscribe(id)
    release_site()

    assert_receive {:page, %{url: @root}, _stats}, @timeout
    assert_receive {:held_request, "/held", held_worker}, @timeout
    assert Crawl.stop(id) == :ok
    {stats, reason} = await_finished()
    {:ok, snapshot} = Crawl.snapshot(id)
    send(held_worker, :release)

    assert reason == :stopped
    assert stats.visited == 1
    assert Map.has_key?(snapshot.pages, @root)
    refute Map.has_key?(snapshot.pages, held_url)
  end

  test "stopping a finished crawl succeeds without another finished event" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nDisallow: /"),
      "/" => html("Home")
    }

    crawl = crawl(site)

    assert Crawl.stop(crawl.id) == :ok
    refute_receive {:finished, _, _}, 100
  end

  test "a finished crawl remains available through snapshot" do
    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nDisallow: /"),
      "/" => html("Home")
    }

    crawl = crawl(site)

    assert {:ok, snapshot} = Crawl.snapshot(crawl.id)
    assert snapshot.status == :finished
    assert snapshot.finished_reason == :disallowed
  end

  test "robots-disallowed links are not visited" do
    private_url = "https://example.com/private"

    site = %{
      "/robots.txt" => robots("User-agent: crawlview\nDisallow: /private"),
      "/" => html("<a href='/public'>Public</a><a href='/private'>Private</a>"),
      "/public" => html("Public"),
      "/private" => html("Private")
    }

    crawl = crawl(site)

    assert crawl.reason == :completed

    assert crawl.snapshot.pages[@root].links == [
             "https://example.com/public",
             private_url
           ]

    refute Map.has_key?(crawl.snapshot.pages, private_url)
    refute_receive {:fake_request, "/private"}, 50
  end

  defp crawl(site, opts \\ []) do
    configure_site(site)
    # The production default paces requests so a person can watch the crawl happen.
    # Tests are not watching, so they opt out and stay fast.
    {:ok, id} = Crawl.start(@root, Keyword.put_new(opts, :min_interval_ms, 0))
    :ok = Crawl.subscribe(id)
    release_site()
    {stats, reason} = await_finished()
    {:ok, snapshot} = Crawl.snapshot(id)

    %{id: id, stats: stats, reason: reason, snapshot: snapshot}
  end

  defp await_finished do
    receive do
      {:finished, stats, reason} -> {stats, reason}
    after
      @timeout -> flunk("crawl did not finish within #{@timeout} ms")
    end
  end

  defp receive_page_events(count) do
    Enum.map(1..count, fn _number ->
      receive do
        {:page, page, _stats} -> page
      after
        @timeout -> flunk("did not receive a page event within #{@timeout} ms")
      end
    end)
  end

  defp configure_site(site) do
    table = Process.get(:crawl_fake_site)
    true = :ets.delete(table, :subscription_ready)
    true = :ets.insert(table, {:site, site})
  end

  defp release_site do
    true = :ets.insert(Process.get(:crawl_fake_site), {:subscription_ready, true})
  end

  defp await_subscription(table) do
    case :ets.lookup(table, :subscription_ready) do
      [{:subscription_ready, true}] ->
        :ok

      [] ->
        receive do
        after
          1 -> await_subscription(table)
        end
    end
  end

  defp robots(body), do: response(200, "text/plain", body)
  defp html(body, status \\ 200), do: response(status, "text/html", body)
  defp redirect(location), do: {302, [{"location", location}, {"content-type", "text/html"}], ""}
  defp response(status, content_type, body), do: {status, [{"content-type", content_type}], body}
end
