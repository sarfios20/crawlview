defmodule CrawlviewWeb.PageController do
  use CrawlviewWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
