defmodule Crawlview.Crawl.Frontier do
  @moduledoc """
  Owns the pure scheduling state for a crawl's pending URLs.

  It answers which URL may start next, and when, without processes or timers.
  The caller supplies the current time rather than this module reading it, which
  keeps scheduling decisions deterministic and directly testable.
  """

  @type item :: %{
          url: String.t(),
          depth: non_neg_integer(),
          referrer: String.t() | nil
        }

  @opaque t :: %__MODULE__{
            queue: :queue.queue(item()),
            seen: MapSet.t(String.t()),
            host_counts: %{optional(String.t()) => pos_integer()},
            next_host_start: %{optional(String.t()) => integer()},
            per_host: pos_integer()
          }

  defstruct queue: :queue.new(),
            seen: MapSet.new(),
            host_counts: %{},
            next_host_start: %{},
            per_host: 1

  @spec new(item(), per_host :: pos_integer()) :: t()
  def new(item, per_host) do
    %__MODULE__{
      queue: :queue.in(item, :queue.new()),
      seen: MapSet.new([item.url]),
      per_host: per_host
    }
  end

  @spec put(t(), [String.t()], depth :: non_neg_integer(), referrer :: String.t()) :: t()
  def put(frontier, urls, depth, referrer) do
    Enum.reduce(urls, frontier, fn url, acc ->
      if MapSet.member?(acc.seen, url) do
        acc
      else
        item = %{url: url, depth: depth, referrer: referrer}

        %{acc | queue: :queue.in(item, acc.queue), seen: MapSet.put(acc.seen, url)}
      end
    end)
  end

  @spec take(t(), now_ms :: integer()) ::
          {:ok, item(), t()} | {:wait, pos_integer()} | :blocked | :empty
  def take(frontier, now_ms) do
    items = :queue.to_list(frontier.queue)

    case Enum.split_while(items, fn item ->
           not host_ready?(frontier, host(item.url), now_ms)
         end) do
      {[], []} ->
        :empty

      {_blocked, []} ->
        case earliest_wait_ms(frontier, items, now_ms) do
          nil -> :blocked
          wait_ms -> {:wait, wait_ms}
        end

      {blocked, [item | rest]} ->
        {:ok, item, %{frontier | queue: :queue.from_list(blocked ++ rest)}}
    end
  end

  @spec started(t(), item(), now_ms :: integer(), delay_ms :: non_neg_integer()) :: t()
  def started(frontier, item, now_ms, delay_ms) do
    item_host = host(item.url)

    %{
      frontier
      | host_counts: Map.update(frontier.host_counts, item_host, 1, &(&1 + 1)),
        next_host_start: Map.put(frontier.next_host_start, item_host, now_ms + delay_ms)
    }
  end

  @spec finished(t(), host :: String.t()) :: t()
  def finished(frontier, host) do
    host_counts = Map.update!(frontier.host_counts, host, &(&1 - 1))

    host_counts =
      if Map.fetch!(host_counts, host) == 0,
        do: Map.delete(host_counts, host),
        else: host_counts

    %{frontier | host_counts: host_counts}
  end

  @spec clear(t()) :: t()
  def clear(frontier) do
    %{
      frontier
      | queue: :queue.new(),
        seen: MapSet.new(),
        host_counts: %{},
        next_host_start: %{}
    }
  end

  @spec queued(t()) :: non_neg_integer()
  def queued(frontier), do: :queue.len(frontier.queue)

  @spec empty?(t()) :: boolean()
  def empty?(frontier), do: :queue.is_empty(frontier.queue)

  defp host_ready?(frontier, host, now_ms) do
    # A host with no recorded start time is ready immediately, so the default
    # must be `now_ms` and never a literal like 0. Monotonic time has no epoch and
    # is large and NEGATIVE on the BEAM, so `0` reads as "far in the future" and
    # would hold every host back forever: the crawl would sit with a full
    # frontier and dispatch nothing at all.
    Map.get(frontier.host_counts, host, 0) < frontier.per_host and
      Map.get(frontier.next_host_start, host, now_ms) <= now_ms
  end

  defp earliest_wait_ms(frontier, items, now_ms) do
    items
    |> Enum.filter(fn item ->
      Map.get(frontier.host_counts, host(item.url), 0) < frontier.per_host
    end)
    |> Enum.map(fn item ->
      max(Map.get(frontier.next_host_start, host(item.url), now_ms) - now_ms, 1)
    end)
    |> Enum.min(fn -> nil end)
  end

  defp host(url), do: URI.parse(url).host
end
