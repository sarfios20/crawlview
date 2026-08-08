defmodule Crawlview.Crawl.Server do
  @moduledoc """
  Owns and schedules all mutable state for one isolated crawl.

  This process is private; callers use `Crawlview.Crawl` so its process topology
  and scheduling protocol do not escape the deep module.
  """

  use GenServer

  alias Crawlview.{Extractor, Fetcher, Page, Robots, Stats, Url}
  alias Crawlview.Crawl.State

  @registry Crawlview.Crawl.Registry
  @task_supervisor Crawlview.Crawl.TaskSupervisor
  @broken_outcomes [:not_found, :client_error, :server_error, :timeout, :unreachable]

  @defaults %{
    max_pages: 200,
    max_depth: 5,
    concurrency: 8,
    per_host: 2,
    timeout_ms: 10_000,
    budget_ms: 120_000
  }

  # These documented server-side maxima bound memory, sockets, and time even
  # when options come from a hostile client: 2,000 pages, depth 20, 32 global
  # requests, 8 requests per host, a 60,000 ms fetch timeout, and a 600,000 ms
  # crawl budget. All duration values in this server are milliseconds.
  @maximums %{
    max_pages: 2_000,
    max_depth: 20,
    concurrency: 32,
    per_host: 8,
    timeout_ms: 60_000,
    budget_ms: 600_000
  }

  # Invariants:
  #
  #   * Single writer: only this Server mutates crawl state. Workers compute and
  #     report results; they never own or update crawler state.
  #   * `seen` is crawl-wide. A URL enters pages at most once, and the frontier
  #     contains no URL already visited or in flight.
  #   * Host counts never exceed `per_host`, and total in-flight work never
  #     exceeds `concurrency`. Worth knowing which one actually binds: because a
  #     crawl stays on one site, every URL shares a host, so `per_host` is the
  #     real throttle and `concurrency` is only the outer bound. That is the
  #     intended order. Politeness to the one server we are a guest on decides
  #     how fast we go, not how much parallelism the machine could afford.
  #   * Workers are supervised and unlinked. A crash or worker timeout loses one
  #     page, never the crawl.
  #   * Stopping preserves completed pages and only abandons queued/in-flight work.
  #   * Completion has exactly one cause: an empty frontier with nothing in
  #     flight, `max_pages`, elapsed `budget_ms`, or stop. `finish/2` makes
  #     exactly one finished broadcast.
  #   * A page at `max_depth` is fetched and records its normalized links, but
  #     those deeper links are not added to the frontier.

  defstruct public: nil,
            opts: nil,
            frontier: :queue.new(),
            seen: MapSet.new(),
            robots: nil,
            in_flight: %{},
            host_counts: %{},
            next_host_start: %{},
            started_monotonic_ms: nil,
            budget_timer: nil,
            dispatch_timer: nil

  @doc false
  @spec start_link({String.t(), String.t(), keyword()}) :: GenServer.on_start()
  def start_link({id, root_url, opts}) do
    GenServer.start_link(__MODULE__, {id, root_url, opts}, name: via(id))
  end

  @doc false
  @spec child_spec({String.t(), String.t(), keyword()}) :: Supervisor.child_spec()
  def child_spec(argument) do
    %{
      id: {__MODULE__, elem(argument, 0)},
      start: {__MODULE__, :start_link, [argument]},
      restart: :temporary
    }
  end

  @impl true
  def init({id, root_url, raw_opts}) do
    started_at = DateTime.utc_now()
    root = %{url: root_url, depth: 0, referrer: nil}
    stats = %Stats{started_at: started_at, queued: 1}

    public = %State{
      id: id,
      root_url: root_url,
      status: :running,
      pages: %{},
      stats: stats,
      finished_reason: nil
    }

    data = %__MODULE__{
      public: public,
      opts: clamp_options(raw_opts),
      frontier: :queue.in(root, :queue.new()),
      seen: MapSet.new([root_url]),
      started_monotonic_ms: now_ms()
    }

    # Robots loading is the crawl's first network operation. Deferring it keeps
    # Crawl.start/2 responsive while still ordering policy before page dispatch.
    {:ok, data, {:continue, :load_robots}}
  end

  @impl true
  def handle_continue(:load_robots, data) do
    robots = Robots.load(data.public.root_url)

    remaining_budget_ms =
      max(data.opts.budget_ms - (now_ms() - data.started_monotonic_ms), 0)

    budget_timer = Process.send_after(self(), :budget_elapsed, remaining_budget_ms)
    data = %{data | robots: robots, budget_timer: budget_timer}

    if Robots.allowed?(robots, data.public.root_url) do
      {:noreply, dispatch(data)}
    else
      # A site that forbids us gets its own finishing reason. Reporting this as
      # :completed would be technically true and useless: the person watching
      # would see an empty screen and no reason for it.
      data = %{data | frontier: :queue.new()} |> put_queue_count(0)
      {:noreply, finish(data, :disallowed)}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, data), do: {:reply, data.public, data}

  @impl true
  def handle_cast(:stop, %{public: %{status: :finished}} = data), do: {:noreply, data}

  def handle_cast(:stop, data) do
    {:noreply, finish(data, :stopped)}
  end

  @impl true
  def handle_info(:dispatch, data) do
    {:noreply, data |> clear_dispatch_timer() |> dispatch()}
  end

  def handle_info(:budget_elapsed, %{public: %{status: :finished}} = data),
    do: {:noreply, data}

  def handle_info(:budget_elapsed, data), do: {:noreply, finish(data, :time_limit)}

  def handle_info({reference, %Fetcher.Result{} = result}, data) when is_reference(reference) do
    case Map.pop(data.in_flight, reference) do
      {nil, _in_flight} ->
        {:noreply, data}

      {work, in_flight} ->
        Process.demonitor(reference, [:flush])
        cancel_timer(work.timeout_timer)

        data = %{data | in_flight: in_flight}
        data = release_slot(data, work.host)

        data =
          if data.public.status == :running do
            record_result(data, work.item, result)
          else
            data
          end

        {:noreply, dispatch(data)}
    end
  end

  def handle_info({:worker_timeout, reference}, data) do
    case Map.get(data.in_flight, reference) do
      nil ->
        {:noreply, data}

      work ->
        _ = Task.Supervisor.terminate_child(@task_supervisor, work.pid)
        {:noreply, data}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, data) do
    case Map.pop(data.in_flight, reference) do
      {nil, _in_flight} ->
        {:noreply, data}

      {work, in_flight} ->
        cancel_timer(work.timeout_timer)

        data =
          data
          |> Map.put(:in_flight, in_flight)
          |> release_slot(work.host)
          |> dispatch()

        {:noreply, data}
    end
  end

  defp dispatch(%{public: %{status: :finished}} = data), do: data

  defp dispatch(data) do
    cond do
      budget_elapsed?(data) ->
        finish(data, :time_limit)

      data.public.stats.visited >= data.opts.max_pages and map_size(data.in_flight) == 0 ->
        finish(data, :page_limit)

      frontier_empty?(data) and map_size(data.in_flight) == 0 ->
        finish(data, :completed)

      dispatch_capacity?(data) ->
        case take_dispatchable(data) do
          {:ok, item, data} -> data |> start_worker(item) |> dispatch()
          {:wait, wait_ms, data} -> schedule_dispatch(data, wait_ms)
          {:blocked, data} -> data
        end

      true ->
        data
    end
  end

  defp dispatch_capacity?(data) do
    map_size(data.in_flight) < data.opts.concurrency and
      data.public.stats.visited + map_size(data.in_flight) < data.opts.max_pages and
      not frontier_empty?(data)
  end

  defp take_dispatchable(data) do
    now = now_ms()
    items = :queue.to_list(data.frontier)

    case Enum.split_while(items, fn item -> not host_ready?(data, host(item.url), now) end) do
      {_blocked, []} ->
        case earliest_wait_ms(data, items, now) do
          nil -> {:blocked, data}
          wait_ms -> {:wait, wait_ms, data}
        end

      {blocked, [item | rest]} ->
        frontier = :queue.from_list(blocked ++ rest)
        data = %{data | frontier: frontier} |> put_queue_count(length(blocked) + length(rest))
        {:ok, item, data}
    end
  end

  defp host_ready?(data, host, now) do
    Map.get(data.host_counts, host, 0) < data.opts.per_host and
      Map.get(data.next_host_start, host, 0) <= now
  end

  defp earliest_wait_ms(data, items, now) do
    items
    |> Enum.filter(fn item ->
      Map.get(data.host_counts, host(item.url), 0) < data.opts.per_host
    end)
    |> Enum.map(fn item -> max(Map.get(data.next_host_start, host(item.url), now) - now, 1) end)
    |> Enum.min(fn -> nil end)
  end

  defp start_worker(data, item) do
    server = self()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Fetcher.fetch(item.url, timeout_ms: data.opts.timeout_ms)
      end)

    host = host(item.url)

    # Fetcher has its own timeout; this slightly wider watchdog also contains a
    # wedged adapter or worker. It is measured in milliseconds.
    timeout_timer =
      Process.send_after(server, {:worker_timeout, task.ref}, data.opts.timeout_ms + 1_000)

    work = %{pid: task.pid, host: host, item: item, timeout_timer: timeout_timer}
    in_flight = Map.put(data.in_flight, task.ref, work)
    host_counts = Map.update(data.host_counts, host, 1, &(&1 + 1))
    delay_ms = Robots.crawl_delay(data.robots)
    next_host_start = Map.put(data.next_host_start, host, now_ms() + delay_ms)

    data
    |> Map.put(:in_flight, in_flight)
    |> Map.put(:host_counts, host_counts)
    |> Map.put(:next_host_start, next_host_start)
    |> put_in_flight_count(map_size(in_flight))
  end

  defp record_result(data, item, result) do
    {title, links} = page_content(result, item.url, data.public.root_url)

    page = %Page{
      url: item.url,
      depth: item.depth,
      referrer: item.referrer,
      outcome: result.outcome,
      status: result.status,
      title: title,
      links: links,
      duration_ms: result.duration_ms
    }

    stats = update_result_stats(data.public.stats, result.outcome)
    public = %{data.public | pages: Map.put(data.public.pages, page.url, page), stats: stats}
    data = %{data | public: public}

    data =
      if item.depth < data.opts.max_depth do
        enqueue_links(data, links, item.depth + 1, item.url)
      else
        data
      end

    # The event carries the post-discovery counters, so subscribers can render
    # the frontier accurately without maintaining a second copy of crawl state.
    :ok =
      Phoenix.PubSub.broadcast(
        Crawlview.PubSub,
        topic(data),
        {:page, page, data.public.stats}
      )

    data
  end

  defp page_content(%Fetcher.Result{outcome: :ok, body: body}, base, root)
       when is_binary(body) do
    %{title: title, hrefs: hrefs} = Extractor.extract(body)
    {title, Url.visitable(hrefs, base, root)}
  end

  defp page_content(%Fetcher.Result{outcome: :redirect, redirect_to: redirect_to}, base, root)
       when is_binary(redirect_to) do
    {nil, Url.visitable([redirect_to], base, root)}
  end

  defp page_content(_result, _base, _root), do: {nil, []}

  defp enqueue_links(data, links, depth, referrer) do
    Enum.reduce(links, data, fn url, acc ->
      if MapSet.member?(acc.seen, url) or not Robots.allowed?(acc.robots, url) do
        acc
      else
        item = %{url: url, depth: depth, referrer: referrer}
        frontier = :queue.in(item, acc.frontier)

        acc
        |> Map.put(:frontier, frontier)
        |> Map.put(:seen, MapSet.put(acc.seen, url))
        |> put_queue_count(:queue.len(frontier))
      end
    end)
  end

  defp update_result_stats(stats, outcome) do
    stats = %{stats | visited: stats.visited + 1}

    cond do
      outcome == :ok -> %{stats | ok: stats.ok + 1}
      outcome in @broken_outcomes -> %{stats | broken: stats.broken + 1}
      true -> stats
    end
  end

  defp release_slot(data, host) do
    host_counts = Map.update!(data.host_counts, host, &(&1 - 1))
    host_counts = if host_counts[host] == 0, do: Map.delete(host_counts, host), else: host_counts

    data
    |> Map.put(:host_counts, host_counts)
    |> put_in_flight_count(map_size(data.in_flight))
  end

  defp finish(data, reason) do
    cancel_timer(data.budget_timer)
    cancel_timer(data.dispatch_timer)

    Enum.each(data.in_flight, fn {_reference, work} ->
      cancel_timer(work.timeout_timer)
      _ = Task.Supervisor.terminate_child(@task_supervisor, work.pid)
    end)

    stats = %{
      data.public.stats
      | queued: 0,
        in_flight: 0,
        finished_at: DateTime.utc_now()
    }

    public = %{
      data.public
      | status: :finished,
        stats: stats,
        finished_reason: reason
    }

    :ok = Phoenix.PubSub.broadcast(Crawlview.PubSub, topic(data), {:finished, stats, reason})

    # Finished servers deliberately live until the node restarts. This keeps a
    # snapshot readable without persistence; deployment or restart loses it.
    %{
      data
      | public: public,
        frontier: :queue.new(),
        in_flight: %{},
        host_counts: %{},
        dispatch_timer: nil
    }
  end

  defp schedule_dispatch(%{dispatch_timer: nil} = data, wait_ms) do
    %{data | dispatch_timer: Process.send_after(self(), :dispatch, wait_ms)}
  end

  defp schedule_dispatch(data, _wait_ms), do: data

  defp clear_dispatch_timer(data), do: %{data | dispatch_timer: nil}

  defp put_queue_count(data, count) do
    put_in(data.public.stats.queued, count)
  end

  defp put_in_flight_count(data, count) do
    put_in(data.public.stats.in_flight, count)
  end

  defp frontier_empty?(data), do: :queue.is_empty(data.frontier)
  defp budget_elapsed?(data), do: now_ms() - data.started_monotonic_ms >= data.opts.budget_ms
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp host(url), do: URI.parse(url).host
  defp topic(data), do: "crawl:" <> data.public.id

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _ = Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp clamp_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: do_clamp_options(opts), else: @defaults
  end

  defp clamp_options(_invalid), do: @defaults

  defp do_clamp_options(opts) do
    Map.new(@defaults, fn {key, default} ->
      minimum = if key == :max_depth, do: 0, else: 1

      value =
        case Keyword.get(opts, key, default) do
          option when is_integer(option) -> option
          _invalid -> default
        end

      {key, value |> max(minimum) |> min(Map.fetch!(@maximums, key))}
    end)
  end

  defp via(id), do: {:via, Registry, {@registry, id}}
end
