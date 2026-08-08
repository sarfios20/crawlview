defmodule CrawlviewWeb.RateLimitTest do
  # async: false because the limiter is a single named ETS table shared by the node.
  use ExUnit.Case, async: false

  alias CrawlviewWeb.RateLimit

  setup do
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)
    :ok
  end

  test "allows requests up to the limit and refuses the one after" do
    for _attempt <- 1..3 do
      assert RateLimit.take("client-a", 3, 60_000) == :ok
    end

    assert RateLimit.take("client-a", 3, 60_000) == {:error, :rate_limited}
  end

  test "counts each client separately" do
    assert RateLimit.take("client-a", 1, 60_000) == :ok
    assert RateLimit.take("client-a", 1, 60_000) == {:error, :rate_limited}

    # One noisy client must not spend anybody else's allowance.
    assert RateLimit.take("client-b", 1, 60_000) == :ok
  end

  test "a live counter survives a sweep" do
    assert RateLimit.take("client-e", 1, 60_000) == :ok

    send(RateLimit, :sweep)
    _ = :sys.get_state(RateLimit)

    # Still counted, so the client is still limited: sweeping is housekeeping, not amnesty.
    assert RateLimit.take("client-e", 1, 60_000) == {:error, :rate_limited}
  end

  test "a new window restores the allowance" do
    # A one millisecond window makes the boundary observable without sleeping for a
    # realistic one. The window index comes from wall-clock time divided by the width,
    # so a short sleep is guaranteed to land in a later window.
    assert RateLimit.take("client-c", 1, 1) == :ok
    Process.sleep(5)
    assert RateLimit.take("client-c", 1, 1) == :ok
  end

  test "sweeping drops windows that can no longer be read" do
    # Backdated by more than the retention period, so the sweeper must collect it.
    :ets.insert(RateLimit, {{"client-d", System.system_time(:millisecond) - 60 * 60 * 1_000}, 1})
    assert :ets.info(RateLimit, :size) == 1

    send(RateLimit, :sweep)
    # A call round-trip proves the sweep message has been processed.
    _ = :sys.get_state(RateLimit)

    assert :ets.info(RateLimit, :size) == 0
  end
end
