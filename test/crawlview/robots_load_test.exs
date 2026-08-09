defmodule Crawlview.RobotsLoadTest do
  # async: false because these tests stub the HTTP client globally for the node.
  use ExUnit.Case, async: false

  alias Crawlview.Robots

  @root_url "https://example.com/start"

  setup do
    default_options = Req.default_options()
    on_exit(fn -> Req.default_options(default_options) end)
    :ok
  end

  test "a missing robots.txt returns the permissive policy" do
    policy = load_with_plug(fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)

    assert_permissive(policy)
  end

  test "a server error returns the permissive policy" do
    policy =
      load_with_plug(fn conn -> Plug.Conn.send_resp(conn, 500, "internal server error") end)

    assert_permissive(policy)
  end

  test "a transport failure returns the permissive policy" do
    policy = load_with_plug(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert_permissive(policy)
  end

  test "a successful response is parsed" do
    policy =
      load_with_plug(fn conn ->
        Plug.Conn.send_resp(conn, 200, "User-agent: crawlview\nDisallow: /private")
      end)

    refute Robots.allowed?(policy, "https://example.com/private/page")
  end

  test "a redirect to the same host is followed and its policy is used" do
    policy =
      load_with_plug(fn conn ->
        case conn.request_path do
          "/robots.txt" -> redirect(conn, "https://EXAMPLE.com/robots-policy")
          "/robots-policy" -> Plug.Conn.send_resp(conn, 200, disallow_all())
        end
      end)

    refute Robots.allowed?(policy, "https://example.com/anything")
  end

  test "a redirect to a different host is not followed" do
    test_pid = self()

    policy =
      load_with_plug(fn conn ->
        send(test_pid, {:request, conn.host})
        redirect(conn, "http://169.254.169.254/latest/meta-data")
      end)

    assert_permissive(policy)
    assert_receive {:request, "example.com"}
    refute_receive {:request, "169.254.169.254"}
  end

  test "a redirect loop that exhausts the hop allowance returns the permissive policy" do
    test_pid = self()

    policy =
      load_with_plug(fn conn ->
        send(test_pid, {:request, conn.request_path})

        case conn.request_path do
          "/robots.txt" -> redirect(conn, "/redirect-1")
          "/redirect-1" -> redirect(conn, "/redirect-2")
          "/redirect-2" -> redirect(conn, "/redirect-3")
          "/redirect-3" -> redirect(conn, "/redirect-4")
        end
      end)

    assert_permissive(policy)

    assert_receive {:request, "/robots.txt"}
    assert_receive {:request, "/redirect-1"}
    assert_receive {:request, "/redirect-2"}
    assert_receive {:request, "/redirect-3"}
    refute_receive {:request, "/redirect-4"}
  end

  defp load_with_plug(plug) do
    Req.default_options(Keyword.put(Req.default_options(), :plug, plug))
    Robots.load(@root_url)
  end

  defp redirect(conn, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(302, "redirect")
  end

  defp disallow_all, do: "User-agent: crawlview\nDisallow: /"

  defp assert_permissive(policy) do
    assert Robots.allowed?(policy, "https://example.com/anything")
    assert Robots.crawl_delay(policy) == 0
  end
end
