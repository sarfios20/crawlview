defmodule Crawlview.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @default_max_processes 100

  @impl true
  def start(_type, _args) do
    children = [
      CrawlviewWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:crawlview, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Crawlview.PubSub},
      {Registry, keys: :unique, name: Crawlview.Crawl.Registry},
      # An absolute ceiling on crawl processes, which is a memory guard for this server.
      # The politeness ceiling that protects OTHER people's servers is separate and
      # smaller, lives in Crawlview.Crawl, and counts only crawls that are still running.
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Crawlview.Crawl.Supervisor,
       max_children: Application.get_env(:crawlview, :max_crawl_processes, @default_max_processes)},
      {Task.Supervisor, name: Crawlview.Crawl.TaskSupervisor},
      CrawlviewWeb.RateLimit,
      # Start a worker by calling: Crawlview.Worker.start_link(arg)
      # {Crawlview.Worker, arg},
      # Start to serve requests, typically the last entry
      CrawlviewWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Crawlview.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CrawlviewWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
