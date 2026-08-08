defmodule CrawlviewWeb.PageControllerTest do
  use CrawlviewWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "See a site as it is crawled"
  end
end
