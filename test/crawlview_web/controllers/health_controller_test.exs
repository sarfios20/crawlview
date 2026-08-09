defmodule CrawlviewWeb.HealthControllerTest do
  use CrawlviewWeb.ConnCase, async: true

  test "GET /health reports that the crawler supervision tree is available", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == ~s({"status":"ok"})
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end
end
