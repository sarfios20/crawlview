defmodule CrawlviewWeb.RateLimit do
  @moduledoc """
  A fixed-window request limiter, keyed by whatever the caller uses to identify a
  client.

  This lives in the web layer on purpose. "Who is asking" is a transport question:
  the crawler has no notion of a client, and teaching it one to solve an abuse
  problem would push an HTTP concern into the domain. The domain's own protection is
  a cap on how many crawls may exist at once, which is about the sites being visited
  rather than about who asked.

  Fixed windows are the crude choice and are the right one here. A sliding window
  would smooth the boundary, at the cost of storing a timestamp per request; the
  worst case of a fixed window is that someone gets two windows' worth of requests
  across a boundary, which for "how many crawls may one person start" is a
  difference without a consequence.
  """

  use GenServer

  @table __MODULE__

  # Generously longer than any window this app configures, so a live counter is never
  # swept out from under a client mid-window.
  @retention_ms 5 * 60 * 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records one request against `key` and says whether it is within the allowance.

  Runs in the CALLER's process: it is a single atomic ETS counter update and never
  sends this GenServer a message, so one client's limit check can never queue behind
  another's. The GenServer exists only to own the table and to sweep stale windows.
  """
  @spec take(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def take(key, limit, window_ms) do
    # The key holds the window's START TIME, not its index. An index is only meaningful
    # next to the width that produced it, and the sweeper does not know each caller's
    # width: keying on the index let rows survive forever whenever the two disagreed,
    # which a test caught. A timestamp needs no such agreement.
    window_start = div(System.system_time(:millisecond), window_ms) * window_ms
    count = :ets.update_counter(@table, {key, window_start}, {2, 1}, {{key, window_start}, 0})

    if count <= limit, do: :ok, else: {:error, :rate_limited}
  rescue
    ArgumentError ->
      # The table is gone, which can only mean this process is starting or stopping.
      # Failing open is the right call: a limiter that rejects traffic because its own
      # bookkeeping is unavailable has turned a safeguard into an outage.
      :ok
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    sweep_ms = Keyword.get(opts, :sweep_ms, 60_000)
    schedule_sweep(sweep_ms)
    {:ok, %{sweep_ms: sweep_ms}}
  end

  @impl true
  def handle_info(:sweep, %{sweep_ms: sweep_ms} = state) do
    # A window that started longer ago than the retention period can never be written
    # to again by any caller, whatever width it used, so the row is only taking space.
    cutoff = System.system_time(:millisecond) - @retention_ms
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])

    schedule_sweep(sweep_ms)
    {:noreply, state}
  end

  defp schedule_sweep(sweep_ms), do: Process.send_after(self(), :sweep, sweep_ms)
end
