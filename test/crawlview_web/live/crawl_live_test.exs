defmodule CrawlviewWeb.CrawlLiveTest do
  use CrawlviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Crawlview.{Crawl, Page, Stats}

  setup do
    default_options = Req.default_options()
    example_address = {93, 184, 216, 34}
    resolver_lookup = :inet_db.res_option(:lookup)

    # The sandboxed test runner has no external resolver. Seed OTP's resolver
    # with example.com's public documentation address so start/2 still performs
    # its real hostname lookup while every HTTP call remains behind the Req plug.
    :ok = :inet_db.set_lookup([:file])
    :ok = :inet_db.add_host(example_address, [~c"example.com"])

    on_exit(fn ->
      Req.default_options(default_options)
      :ok = :inet_db.del_host(example_address)
      :ok = :inet_db.set_lookup(resolver_lookup)
    end)

    :ok
  end

  test "renders the crawl form and one-click examples", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#crawl-form")
    assert has_element?(view, "#start-crawl")
    assert has_element?(view, "#crawl-presets button", "The first website (1991)")
    assert has_element?(view, "#crawl-presets button", "elixir-lang.org")
    assert has_element?(view, "#crawl-presets button", "davidhaggstrom.dev")
  end

  test "an invalid URL shows a useful error without starting a crawl", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#crawl-form", crawl: %{url: "ftp://example.com/files"})
    |> render_submit()

    assert has_element?(view, "#url-error", "Use an address beginning with http:// or https://.")
    assert has_element?(view, "#crawl_url[value='ftp://example.com/files']")
    refute has_element?(view, "#crawl-results")
  end

  test "a valid URL starts a crawl and exposes running state and stop", %{conn: conn} do
    hold_root_request()
    {:ok, view, _html} = live(conn, ~p"/")

    # example.com resolves publicly, satisfying start/2's real DNS check; Req's
    # process-wide test plug ensures no HTTP request leaves this machine.
    view
    |> form("#crawl-form", crawl: %{url: "https://example.com/"})
    |> render_submit()

    path = assert_patch(view)
    assert path =~ ~r{^/\?crawl=.+$}
    assert has_element?(view, "#crawl-results")
    assert has_element?(view, "#crawl-stats")
    assert has_element?(view, "#stop-crawl")

    view |> element("#stop-crawl") |> render_click()
  end

  test "stopping a running crawl replaces the button with a human sentence", %{conn: conn} do
    hold_root_request()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#crawl-form", crawl: %{url: "https://example.com/"})
    |> render_submit()

    _path = assert_patch(view)
    id = view |> element("#crawl-id") |> render() |> text_content()
    :ok = Crawl.subscribe(id)

    view |> element("#stop-crawl") |> render_click()
    assert_receive {:finished, _stats, :stopped}
    _state = :sys.get_state(view.pid)

    refute has_element?(view, "#stop-crawl")
    assert has_element?(view, "#finished-reason", "You stopped the crawl.")
  end

  test "a broken link is marked by text and structure, not colour alone", %{conn: conn} do
    serve_tiny_site()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#crawl-form", crawl: %{url: "https://example.com/"})
    |> render_submit()

    _path = assert_patch(view)

    page = %Page{
      url: "https://example.com/missing",
      depth: 1,
      referrer: "https://example.com/",
      outcome: :not_found,
      status: 404,
      title: nil,
      links: [],
      duration_ms: 12
    }

    stats = %Stats{started_at: DateTime.utc_now(), visited: 1, broken: 1}
    send(view.pid, {:page, page, stats})
    _state = :sys.get_state(view.pid)

    assert has_element?(view, "#crawl-pages tr[data-outcome='not_found']")
    assert has_element?(view, "#crawl-pages tr[data-outcome='not_found']", "Broken · not found")
    assert has_element?(view, "#crawl-pages tr[data-outcome='not_found']", "404")
  end

  defp hold_root_request do
    test_process = self()

    install_plug(fn conn ->
      case conn.request_path do
        "/robots.txt" ->
          Plug.Conn.send_resp(conn, 404, "not found")

        _path ->
          send(test_process, {:root_request_waiting, self()})

          receive do
            :release -> Req.Test.html(conn, "<html><title>Held page</title></html>")
          end
      end
    end)
  end

  defp serve_tiny_site do
    install_plug(fn conn ->
      case conn.request_path do
        "/robots.txt" ->
          Plug.Conn.send_resp(conn, 404, "not found")

        "/missing" ->
          Plug.Conn.send_resp(conn, 404, "missing")

        _root ->
          Req.Test.html(
            conn,
            "<html><title>Tiny site</title><a href='/missing'>Missing page</a></html>"
          )
      end
    end)
  end

  defp install_plug(plug) do
    options = Keyword.merge(Req.default_options(), plug: plug, retry: false)
    Req.default_options(options)
  end

  defp text_content(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end
end
