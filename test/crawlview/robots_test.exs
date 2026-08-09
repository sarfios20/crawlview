defmodule Crawlview.RobotsTest do
  use ExUnit.Case, async: true

  alias Crawlview.Robots

  test "an empty robots.txt allows every path with no crawl delay" do
    policy = Robots.parse("")

    assert Robots.allowed?(policy, "https://example.com/anything")
    assert Robots.crawl_delay(policy) == 0
  end

  test "garbage with no rules allows every path with no crawl delay" do
    policy = Robots.parse("this is not a robots file\n!@#$%^&*()")

    assert Robots.allowed?(policy, "https://example.com/anything")
    assert Robots.crawl_delay(policy) == 0
  end

  test "non-binary input returns the permissive policy" do
    policy = Robots.parse(nil)

    assert Robots.allowed?(policy, "https://example.com/anything")
    assert Robots.crawl_delay(policy) == 0
  end

  test "permissive policy allows every path with no crawl delay" do
    policy = Robots.permissive()

    assert Robots.allowed?(policy, "https://example.com/anything")
    assert Robots.crawl_delay(policy) == 0
  end

  test "Disallow slash blocks every path including the site root" do
    policy = Robots.parse("User-agent: crawlview\nDisallow: /")

    refute Robots.allowed?(policy, "https://example.com/")
    refute Robots.allowed?(policy, "https://example.com/elsewhere")
  end

  test "Disallow private blocks that prefix but not public paths" do
    policy = Robots.parse("User-agent: crawlview\nDisallow: /private")

    refute Robots.allowed?(policy, "https://example.com/private")
    refute Robots.allowed?(policy, "https://example.com/private/page")
    assert Robots.allowed?(policy, "https://example.com/public")
  end

  test "an empty Disallow value disallows nothing" do
    policy = Robots.parse("User-agent: crawlview\nDisallow:")

    assert Robots.allowed?(policy, "https://example.com/")
    assert Robots.allowed?(policy, "https://example.com/private")
  end

  test "a longer Allow rule beats a shorter Disallow rule" do
    policy =
      Robots.parse("""
      User-agent: crawlview
      Disallow: /a
      Allow: /a/b
      """)

    assert Robots.allowed?(policy, "https://example.com/a/b/c")
    refute Robots.allowed?(policy, "https://example.com/a/x")
  end

  test "the longest matching rule wins regardless of rule order" do
    allow_first =
      Robots.parse("""
      User-agent: crawlview
      Allow: /shop
      Disallow: /shop/checkout
      """)

    disallow_first =
      Robots.parse("""
      User-agent: crawlview
      Disallow: /shop/checkout
      Allow: /shop
      """)

    refute Robots.allowed?(allow_first, "https://example.com/shop/checkout/payment")
    refute Robots.allowed?(disallow_first, "https://example.com/shop/checkout/payment")
  end

  test "equally long Allow and Disallow rules favour Allow" do
    policy =
      Robots.parse("""
      User-agent: crawlview
      Disallow: /same
      Allow: /same
      """)

    assert Robots.allowed?(policy, "https://example.com/same/page")
  end

  test "a path matching no rule is allowed" do
    policy = Robots.parse("User-agent: crawlview\nDisallow: /private")

    assert Robots.allowed?(policy, "https://example.com/unmatched")
  end

  test "the crawler group takes precedence over a more permissive wildcard group" do
    policy =
      Robots.parse("""
      User-agent: *
      Allow: /

      User-agent: crawlview
      Disallow: /
      """)

    refute Robots.allowed?(policy, "https://example.com/public")
  end

  test "the crawler group takes precedence over a more restrictive wildcard group" do
    policy =
      Robots.parse("""
      User-agent: *
      Disallow: /

      User-agent: crawlview
      Allow: /
      """)

    assert Robots.allowed?(policy, "https://example.com/public")
  end

  test "when no user-agent group matches every path is allowed" do
    policy = Robots.parse("User-agent: another-crawler\nDisallow: /")

    assert Robots.allowed?(policy, "https://example.com/private")
  end

  test "consecutive user-agent lines share the directives that follow" do
    policy =
      Robots.parse("""
      User-agent: another-crawler
      User-agent: crawlview
      Disallow: /shared
      """)

    refute Robots.allowed?(policy, "https://example.com/shared/page")
  end

  test "comments are ignored" do
    policy =
      Robots.parse("""
      User-agent: crawlview # policy for this crawler
      Disallow: /private # keep this area out
      """)

    refute Robots.allowed?(policy, "https://example.com/private/page")
  end

  test "blank lines are ignored" do
    policy =
      Robots.parse("""
      User-agent: crawlview


      Disallow: /private
      """)

    refute Robots.allowed?(policy, "https://example.com/private/page")
  end

  test "directive names are case-insensitive" do
    policy = Robots.parse("USER-AGENT: crawlview\ndisallow: /private")

    refute Robots.allowed?(policy, "https://example.com/private/page")
  end

  test "an integer crawl delay in seconds is returned in milliseconds" do
    policy = Robots.parse("User-agent: crawlview\nCrawl-delay: 2")

    assert Robots.crawl_delay(policy) == 2_000
  end

  test "a fractional crawl delay in seconds is returned in milliseconds" do
    policy = Robots.parse("User-agent: crawlview\nCrawl-delay: 0.5")

    assert Robots.crawl_delay(policy) == 500
  end

  test "an unparseable crawl delay yields zero" do
    policy = Robots.parse("User-agent: crawlview\nCrawl-delay: soon")

    assert Robots.crawl_delay(policy) == 0
  end

  test "an absent crawl delay yields zero" do
    policy = Robots.parse("User-agent: crawlview\nDisallow: /private")

    assert Robots.crawl_delay(policy) == 0
  end

  test "the crawl delay comes from the selected group rather than the first group" do
    policy =
      Robots.parse("""
      User-agent: *
      Crawl-delay: 9

      User-agent: crawlview
      Crawl-delay: 2
      """)

    assert Robots.crawl_delay(policy) == 2_000
  end
end
