defmodule Crawlview.Crawl.FrontierTest do
  use ExUnit.Case, async: true

  alias Crawlview.Crawl.Frontier

  @root %{url: "https://example.com/", depth: 0, referrer: nil}

  test "a host without a start time is ready at a negative monotonic time" do
    frontier = Frontier.new(@root, 1)

    assert {:ok, @root, frontier} = Frontier.take(frontier, -1_000_000_000)
    assert Frontier.empty?(frontier)
  end

  test "a pacing host reports the remaining wait" do
    frontier = Frontier.new(@root, 2)
    {:ok, item, frontier} = Frontier.take(frontier, -10_000)
    frontier = Frontier.started(frontier, item, -10_000, 350)
    frontier = Frontier.put(frontier, ["https://example.com/next"], 1, @root.url)

    assert {:wait, 225} = Frontier.take(frontier, -9_875)
  end

  test "all items at their per-host limit are blocked" do
    frontier = Frontier.new(@root, 1)
    {:ok, item, frontier} = Frontier.take(frontier, 100)
    frontier = Frontier.started(frontier, item, 100, 0)
    frontier = Frontier.put(frontier, ["https://example.com/next"], 1, @root.url)

    assert :blocked = Frontier.take(frontier, 100)
  end

  test "a blocked item is skipped and remains queued" do
    frontier = Frontier.new(@root, 1)
    {:ok, item, frontier} = Frontier.take(frontier, 100)
    frontier = Frontier.started(frontier, item, 100, 0)

    frontier =
      Frontier.put(
        frontier,
        ["https://example.com/blocked", "https://other.example/ready"],
        1,
        @root.url
      )

    assert {:ok, %{url: "https://other.example/ready"}, frontier} =
             Frontier.take(frontier, 100)

    assert 1 == Frontier.queued(frontier)
    assert :blocked = Frontier.take(frontier, 100)
  end

  test "put deduplicates seen URLs and preserves document order" do
    frontier = Frontier.new(@root, 1)

    frontier =
      Frontier.put(
        frontier,
        ["https://example.com/a", @root.url, "https://example.com/b", "https://example.com/a"],
        1,
        @root.url
      )

    assert {:ok, @root, frontier} = Frontier.take(frontier, 0)
    assert {:ok, %{url: "https://example.com/a"}, frontier} = Frontier.take(frontier, 0)
    assert {:ok, %{url: "https://example.com/b"}, frontier} = Frontier.take(frontier, 0)
    assert :empty = Frontier.take(frontier, 0)
  end

  test "finishing work frees its host slot" do
    frontier = Frontier.new(@root, 1)
    {:ok, item, frontier} = Frontier.take(frontier, 100)
    frontier = Frontier.started(frontier, item, 100, 0)
    frontier = Frontier.put(frontier, ["https://example.com/next"], 1, @root.url)

    assert :blocked = Frontier.take(frontier, 100)

    frontier = Frontier.finished(frontier, "example.com")

    assert {:ok, %{url: "https://example.com/next"}, _frontier} = Frontier.take(frontier, 100)
  end

  test "clear releases queued, seen, and host scheduling state while preserving per-host" do
    frontier = Frontier.new(@root, 1)
    {:ok, item, frontier} = Frontier.take(frontier, 100)
    frontier = Frontier.started(frontier, item, 100, 1_000)
    frontier = Frontier.put(frontier, ["https://example.com/stale"], 1, @root.url)

    frontier = Frontier.clear(frontier)

    assert Frontier.empty?(frontier)
    assert 0 == Frontier.queued(frontier)

    frontier = Frontier.put(frontier, [@root.url, "https://example.com/next"], 1, @root.url)
    assert {:ok, %{url: "https://example.com/"} = item, frontier} = Frontier.take(frontier, 100)

    frontier = Frontier.started(frontier, item, 100, 0)
    assert :blocked = Frontier.take(frontier, 100)
  end
end
