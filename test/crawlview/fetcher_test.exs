defmodule Crawlview.FetcherTest do
  use ExUnit.Case, async: true

  alias Crawlview.Fetcher
  alias Crawlview.Fetcher.Result

  @url "https://example.com/page"

  describe ":ok outcome" do
    test "returns an HTML response body" do
      html = "<html><body>Hello</body></html>"
      plug = fn conn -> Req.Test.html(conn, html) end

      assert %Result{
               outcome: :ok,
               status: 200,
               content_type: content_type,
               redirect_to: nil,
               body: ^html,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, plug: plug)

      assert String.starts_with?(content_type, "text/html")
      assert_duration(duration_ms)
    end
  end

  describe ":redirect outcome" do
    test "resolves a relative Location header against the requested URL" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/new-page")
        |> Plug.Conn.send_resp(301, "redirect body is discarded")
      end

      assert %Result{
               outcome: :redirect,
               status: 301,
               content_type: nil,
               redirect_to: "https://example.com/new-page",
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch("https://example.com/old-page", plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe ":not_found outcome" do
    test "normalizes a 404 response" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 404, "missing") end

      assert %Result{
               outcome: :not_found,
               status: 404,
               content_type: nil,
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe ":client_error outcome" do
    test "normalizes a non-404 4xx response" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 403, "forbidden") end

      assert %Result{
               outcome: :client_error,
               status: 403,
               content_type: nil,
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe ":server_error outcome" do
    test "normalizes a 5xx response" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "failure") end

      assert %Result{
               outcome: :server_error,
               status: 500,
               content_type: nil,
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe ":timeout outcome" do
    test "normalizes a transport timeout" do
      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert %Result{
               outcome: :timeout,
               status: nil,
               content_type: nil,
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe ":unreachable outcome" do
    test "normalizes a refused connection" do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      assert %Result{
               outcome: :unreachable,
               status: nil,
               content_type: nil,
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe ":not_html outcome" do
    test "discards a non-HTML response body" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/pdf")
        |> Plug.Conn.send_resp(200, "%PDF-1.7 non-empty body")
      end

      assert %Result{
               outcome: :not_html,
               status: 200,
               content_type: "application/pdf",
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe ":too_large outcome" do
    test "rejects a chunked body that exceeds max_bytes without a content-length header" do
      body = String.duplicate("x", 50)

      plug = fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, body)
        conn
      end

      assert %Result{
               outcome: :too_large,
               status: 200,
               content_type: "text/html",
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, max_bytes: 10, plug: plug)

      assert_duration(duration_ms)
    end

    test "rejects a response whose advertised content length exceeds max_bytes" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.put_resp_header("content-length", "50")
        |> Plug.Conn.send_resp(200, "short")
      end

      assert %Result{
               outcome: :too_large,
               status: 200,
               content_type: "text/html",
               redirect_to: nil,
               body: nil,
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, max_bytes: 10, plug: plug)

      assert_duration(duration_ms)
    end
  end

  describe "total-function guarantee" do
    test "returns a Result for an unparseable URL without a plug" do
      assert %Result{} = Fetcher.fetch("not a url at all \n\t", timeout_ms: 100)
    end

    test "returns a Result when a request without a plug fails locally" do
      assert %Result{} = Fetcher.fetch("http://127.0.0.1:1", timeout_ms: 100)
    end

    test "raises on an invalid option rather than reporting it as a failed fetch" do
      # Totality is a promise about the network, not a promise to swallow caller
      # bugs. A bad option is a defect in the calling code, and disguising it as
      # an unreachable host would hide it behind a plausible-looking Result.
      plug = fn conn -> Req.Test.html(conn, "<html></html>") end

      assert_raise ArgumentError, fn ->
        Fetcher.fetch(@url, timeout_ms: "not a number", plug: plug)
      end

      assert_raise ArgumentError, fn ->
        Fetcher.fetch(@url, max_bytes: -1, plug: plug)
      end
    end
  end

  describe "request shape" do
    test "sends the crawler user-agent and accepts custom timeout and max-byte options" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:observed_user_agent, Plug.Conn.get_req_header(conn, "user-agent")})
        Req.Test.html(conn, "<html></html>")
      end

      assert %Result{
               outcome: :ok,
               status: 200,
               content_type: content_type,
               redirect_to: nil,
               body: "<html></html>",
               duration_ms: duration_ms
             } = Fetcher.fetch(@url, timeout_ms: 250, max_bytes: 100, plug: plug)

      assert_receive {:observed_user_agent,
                      ["Crawlview/0.1 (+https://github.com/sarfios20/crawlview)"]}

      assert String.starts_with?(content_type, "text/html")
      assert_duration(duration_ms)
    end
  end

  defp assert_duration(duration_ms) do
    assert is_integer(duration_ms)
    assert duration_ms >= 0
  end
end
