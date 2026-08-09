defmodule CrawlviewWeb.HealthController do
  @moduledoc """
  Reports whether the processes required to run crawls are available.
  """

  use CrawlviewWeb, :controller

  @required_processes [
    Crawlview.Crawl.Supervisor,
    Crawlview.Crawl.Registry,
    Crawlview.Crawl.TaskSupervisor
  ]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    # json/2 negotiates formats, so an unsupported Accept could return 406 and make the platform
    # kill a healthy process.
    if Enum.all?(@required_processes, &alive?/1) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:ok, ~s({"status":"ok"}))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:service_unavailable, ~s({"status":"unavailable"}))
    end
  end

  defp alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end
end
