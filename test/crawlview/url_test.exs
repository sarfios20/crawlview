defmodule Crawlview.UrlTest do
  use ExUnit.Case, async: true

  alias Crawlview.Url

  describe "visitable/3" do
    test "resolves a bare relative path against the base directory" do
      assert Url.visitable(
               ["about"],
               "https://example.com/docs/page",
               "https://example.com/"
             ) == ["https://example.com/docs/about"]
    end

    test "resolves a dot-relative path against the base directory" do
      assert Url.visitable(
               ["./about"],
               "https://example.com/docs/page",
               "https://example.com/"
             ) == ["https://example.com/docs/about"]
    end

    test "resolves a parent-relative path against the base directory" do
      assert Url.visitable(
               ["../about"],
               "https://example.com/docs/page",
               "https://example.com/"
             ) == ["https://example.com/about"]
    end

    test "resolves a root-relative path against the site root" do
      assert Url.visitable(
               ["/about"],
               "https://example.com/docs/page",
               "https://example.com/"
             ) == ["https://example.com/about"]
    end

    test "collapses parent traversal that escapes past the root" do
      assert Url.visitable(
               ["../../../../about"],
               "https://example.com/a/b/page",
               "https://example.com/"
             ) == ["https://example.com/about"]
    end

    test "inherits the base scheme for a protocol-relative URL" do
      assert Url.visitable(
               ["//example.com/about"],
               "https://example.com/docs/page",
               "https://example.com/"
             ) == ["https://example.com/about"]
    end

    test "drops fragments so references to the same resource deduplicate" do
      assert Url.visitable(
               ["/a#top", "/a"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/a"]
    end

    test "omits fragment-only hrefs" do
      assert Url.visitable(["#top"], "https://example.com/a", "https://example.com/") == []
    end

    test "omits empty hrefs" do
      assert Url.visitable([""], "https://example.com/a", "https://example.com/") == []
    end

    test "omits non-HTTP schemes" do
      hrefs = [
        "mailto:hello@example.com",
        "tel:+12025550123",
        "javascript:void(0)",
        "data:text/plain,hello"
      ]

      assert Url.visitable(hrefs, "https://example.com/", "https://example.com/") == []
    end

    test "omits URLs on other hosts" do
      assert Url.visitable(
               ["https://other.example/about"],
               "https://example.com/",
               "https://example.com/"
             ) == []
    end

    test "the www spelling is a different host, so it is not same-site" do
      # Deliberately strict, and it is a security property rather than pedantry. Only the
      # root's host is DNS-checked, so if `www.x` counted as `x` then a page on a public
      # host could link to its own www spelling, that name could resolve to something
      # private, and the crawl would fetch it having validated nothing. A site that
      # answers under two names is handled by the root following its own redirect, and
      # that path does validate the name it adopts.
      assert Url.visitable(
               ["https://www.example.com/about"],
               "https://example.com/",
               "https://example.com/"
             ) == []

      assert Url.visitable(
               ["https://example.com/about"],
               "https://www.example.com/",
               "https://www.example.com/"
             ) == []
    end

    test "every URL it returns carries the root's exact host" do
      # The invariant the whole SSRF argument rests on: nothing is ever fetched whose host
      # is not the one that was already checked.
      urls =
        Url.visitable(
          ["/a", "https://example.com/b", "//example.com/c", "https://other.example/d"],
          "https://example.com/",
          "https://example.com/"
        )

      assert Enum.all?(urls, &(URI.parse(&1).host == "example.com"))
      assert length(urls) == 3
    end

    test "lowercases the scheme and host" do
      assert Url.visitable(
               ["HTTP://EXAMPLE.COM/about"],
               "http://example.com/",
               "http://example.com/"
             ) == ["http://example.com/about"]
    end

    test "preserves path case" do
      assert Url.visitable(
               ["/About"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/About"]
    end

    test "drops the default HTTP port" do
      assert Url.visitable(
               ["http://example.com:80/about"],
               "http://example.com/",
               "http://example.com/"
             ) == ["http://example.com/about"]
    end

    test "drops the default HTTPS port" do
      assert Url.visitable(
               ["https://example.com:443/about"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/about"]
    end

    test "keeps a non-default port" do
      assert Url.visitable(
               ["https://example.com:8443/about"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com:8443/about"]
    end

    test "sorts query parameters so reordered queries deduplicate" do
      assert Url.visitable(
               ["/search?b=2&a=1", "/search?a=1&b=2"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/search?a=1&b=2"]
    end

    test "keeps the trailing slash, because /a and /a/ are not the same resource" do
      # This is the regression that made a very ordinary site uncrawlable: many
      # servers answer /a with a redirect to /a/. Folding the two together makes the
      # redirect target equal to its own source, so the crawl treats it as already
      # visited and never advances past depth 1.
      assert Url.visitable(
               ["/about/", "/about"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/about/", "https://example.com/about"]
    end

    test "the documented trailing-slash choice keeps the site root as slash" do
      assert Url.visitable(
               ["https://example.com", "https://example.com/"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/"]
    end

    test "keeps index.html, which is a guess about the server rather than a fact" do
      assert Url.visitable(
               ["/foo/index.html", "/foo/"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/foo/index.html", "https://example.com/foo/"]
    end

    test "keeps the first occurrence position when duplicate URLs are removed" do
      hrefs = ["/first", "/same", "/middle", "/same", "/last"]

      assert Url.visitable(hrefs, "https://example.com/", "https://example.com/") == [
               "https://example.com/first",
               "https://example.com/same",
               "https://example.com/middle",
               "https://example.com/last"
             ]
    end

    test "trims surrounding spaces, tabs, and newlines from hrefs" do
      hrefs = ["  /space  ", "\t/tab\t", "\n/newline\n"]

      assert Url.visitable(hrefs, "https://example.com/", "https://example.com/") == [
               "https://example.com/space",
               "https://example.com/tab",
               "https://example.com/newline"
             ]
    end

    test "accepts and normalizes an uppercase host without raising" do
      assert Url.visitable(
               ["https://EXAMPLE.COM/about"],
               "https://example.com/",
               "https://example.com/"
             ) == ["https://example.com/about"]
    end

    test "accepts and normalizes an IDN Unicode host without raising" do
      assert Url.visitable(
               ["https://MÜNICH.example/Über"],
               "https://münich.example/",
               "https://münich.example/"
             ) == ["https://münich.example/Über"]
    end

    test "hostile href inputs never raise and still return a list" do
      hostile_inputs = [
        "http://",
        ":",
        "http://[::1",
        "//",
        "\n\t",
        String.duplicate("x", 20_000),
        "%zz",
        <<0>>
      ]

      assert is_list(
               Url.visitable(
                 hostile_inputs,
                 "https://example.com/base",
                 "https://example.com/"
               )
             )
    end

    test "always returns binaries and never nil" do
      result =
        Url.visitable(
          ["/valid", nil, <<0>>, "mailto:no@example.com", "/also-valid"],
          "https://example.com/",
          "https://example.com/"
        )

      assert is_list(result)
      assert Enum.all?(result, &is_binary/1)
      refute Enum.any?(result, &is_nil/1)
    end
  end

  describe "public_http_url/1" do
    test "returns invalid_scheme for a non-HTTP scheme" do
      assert Url.public_http_url("ftp://example.com/") == {:error, :invalid_scheme}
    end

    test "returns invalid_url for malformed HTTP input" do
      assert Url.public_http_url("http://[::1") == {:error, :invalid_url}
    end

    test "returns invalid_url when the input has no host" do
      assert Url.public_http_url("http://") == {:error, :invalid_url}
    end

    test "rejects an IPv4 loopback literal as a private address" do
      assert Url.public_http_url("http://127.0.0.1/") == {:error, :private_address}
    end

    test "rejects localhost as a private address" do
      assert Url.public_http_url("http://localhost/") == {:error, :private_address}
    end

    test "rejects an IPv6 loopback literal as a private address" do
      assert Url.public_http_url("http://[::1]/") == {:error, :private_address}
    end

    test "rejects a link-local literal as a private address" do
      assert Url.public_http_url("http://169.254.1.1/") == {:error, :private_address}
    end

    # There is no DNS injection seam. Running this assertion would contact an
    # external resolver, so it remains documented but skipped by default.
    @tag :network
    @tag skip: "requires real external DNS"
    test "normalizes a well-formed public URL after DNS validation" do
      assert Url.public_http_url("HTTPS://EXAMPLE.COM:443/foo/index.html?b=2&a=1#top") ==
               {:ok, "https://example.com/foo/index.html?a=1&b=2"}
    end
  end
end
