defmodule CrawlviewWeb.CrawlControllerTest do
  use CrawlviewWeb.ConnCase, async: false

  alias Crawlview.Crawl

  setup do
    default_options = Req.default_options()
    example_address = {93, 184, 216, 34}
    resolver_lookup = :inet_db.res_option(:lookup)

    :ok = :inet_db.set_lookup([:file])
    :ok = :inet_db.add_host(example_address, [~c"example.com"])

    on_exit(fn ->
      Req.default_options(default_options)
      :ok = :inet_db.del_host(example_address)
      :ok = :inet_db.set_lookup(resolver_lookup)
    end)

    {:ok, conn: put_req_header(build_conn(), "accept", "application/json")}
  end

  test "POST rejects a non-HTTP scheme with a useful JSON error", %{conn: conn} do
    response =
      conn |> post(~p"/api/crawls", %{url: "ftp://example.com/files"}) |> json_response(422)

    assert response == %{
             "error" => %{
               "code" => "invalid_scheme",
               "message" => "Use an address beginning with http:// or https://."
             }
           }
  end

  test "POST rejects a private address with a useful JSON error", %{conn: conn} do
    response = conn |> post(~p"/api/crawls", %{url: "http://127.0.0.1/"}) |> json_response(422)

    assert response["error"]["code"] == "private_address"
    assert response["error"]["message"] =~ "private or reserved network"
  end

  test "POST rejects a missing url instead of crashing", %{conn: conn} do
    response = conn |> post(~p"/api/crawls", %{}) |> json_response(422)

    assert response["error"]["code"] == "invalid_url"
    assert is_binary(response["error"]["message"])
  end

  test "unknown crawls return JSON 404s from both snapshot routes", %{conn: conn} do
    show_response = conn |> get(~p"/api/crawls/unknown") |> json_response(404)

    pages_response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/crawls/unknown/pages")
      |> json_response(404)

    assert show_response["error"]["code"] == "not_found"
    assert pages_response["error"]["code"] == "not_found"
  end

  test "DELETE is idempotent for an unknown crawl", %{conn: conn} do
    conn = delete(conn, ~p"/api/crawls/unknown")
    assert response(conn, 204) == ""
  end

  test "create, show, and pages render one real crawl snapshot", %{conn: conn} do
    test_process = self()

    install_plug(fn request_conn ->
      case request_conn.request_path do
        "/robots.txt" ->
          Plug.Conn.send_resp(request_conn, 404, "not found")

        "/missing" ->
          Plug.Conn.send_resp(request_conn, 404, "missing")

        _root ->
          send(test_process, {:root_request_waiting, self()})

          receive do
            :release ->
              Req.Test.html(
                request_conn,
                "<html><title>Tiny site</title><a href='/missing'>Missing page</a></html>"
              )
          end
      end
    end)

    # min_interval_ms: 0 opts out of the production pacing default, which exists so a
    # person can watch a crawl and would otherwise just make this test wait.
    create_conn =
      post(conn, ~p"/api/crawls", %{
        url: "https://example.com/",
        max_pages: 5,
        min_interval_ms: 0
      })

    %{"id" => id} = json_response(create_conn, 201)

    assert get_resp_header(create_conn, "location") == [~p"/api/crawls/#{id}"]

    :ok = Crawl.subscribe(id)
    assert_receive {:root_request_waiting, worker}
    send(worker, :release)
    assert_receive {:finished, _stats, :completed}, 2_000

    show =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/crawls/#{id}")
      |> json_response(200)

    assert show["id"] == id
    assert show["root_url"] == "https://example.com/"
    assert show["status"] == "finished"
    assert show["finished_reason"] == "completed"
    assert show["stats"]["visited"] == 2
    assert is_binary(show["stats"]["started_at"])
    assert is_binary(show["stats"]["finished_at"])

    pages_response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/crawls/#{id}/pages")
      |> json_response(200)

    assert pages_response["pagination"] == %{
             "has_more" => false,
             "limit" => 100,
             "offset" => 0,
             "returned" => 2,
             "total" => 2
           }

    assert [root_page, missing_page] = pages_response["pages"]
    assert root_page["url"] == "https://example.com/"
    assert root_page["depth"] == 0
    assert root_page["referrer"] == nil
    assert root_page["outcome"] == "ok"

    assert missing_page["url"] == "https://example.com/missing"
    assert missing_page["depth"] == 1
    assert missing_page["referrer"] == "https://example.com/"
    assert missing_page["outcome"] == "not_found"
    assert missing_page["status"] == 404
  end

  defp install_plug(plug) do
    options = Keyword.merge(Req.default_options(), plug: plug, retry: false)
    Req.default_options(options)
  end
end
