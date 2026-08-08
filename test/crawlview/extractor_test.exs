defmodule Crawlview.ExtractorTest do
  use ExUnit.Case, async: true

  alias Crawlview.Extractor

  test "extracts a trimmed title and hrefs in document order from a well-formed page" do
    html = """
    <!doctype html>
    <html>
      <head><title>Example page</title></head>
      <body>
        <a href="/first">First</a>
        <a href="https://example.com/second?from=page#details">Second</a>
        <a href="../third">Third</a>
      </body>
    </html>
    """

    assert Extractor.extract(html) == %{
             title: "Example page",
             hrefs: ["/first", "https://example.com/second?from=page#details", "../third"]
           }
  end

  test "returns nil title when the document has no title tag" do
    html = "<html><body><a href=\"/only-link\">Only link</a></body></html>"

    assert Extractor.extract(html) == %{title: nil, hrefs: ["/only-link"]}
  end

  test "returns an empty href list when the document has no anchor tags" do
    html = "<html><head><title>Linkless</title></head><body><p>No links here.</p></body></html>"

    assert Extractor.extract(html) == %{title: "Linkless", hrefs: []}
  end

  test "recovers title and links from deeply nested malformed markup without raising" do
    html = """
    <html><head><title>Recoverable</title></head><body>
      <main><section><div><p><strong><a href="/deep">Deep link</section>
      <a href="/after">After malformed nesting</a></div></main>
    </body></html>
    """

    assert Extractor.extract(html) == %{title: "Recoverable", hrefs: ["/deep", "/after"]}
  end

  test "parses unclosed paragraph list and document tags without raising" do
    html = """
    <html><head><title>Unclosed tags</title></head><body>
      <p>Introduction
      <ul><li><a href="/one">One<li><a href="/two">Two
    """

    assert Extractor.extract(html) == %{title: "Unclosed tags", hrefs: ["/one", "/two"]}
  end

  test "skips anchors without href while retaining sibling anchors with href" do
    html = """
    <a id="missing-href">No destination</a>
    <a href="/present">Has destination</a>
    """

    assert Extractor.extract(html) == %{title: nil, hrefs: ["/present"]}
  end

  test "extracts uppercase and mixed-case href attributes" do
    html = """
    <A HREF="/uppercase">Uppercase</A>
    <a Href="/mixed-case">Mixed case</a>
    """

    assert Extractor.extract(html) == %{title: nil, hrefs: ["/uppercase", "/mixed-case"]}
  end

  test "trims only outer whitespace from title text" do
    html = "<html><head><title>\n  My Page \t Title  \n</title></head></html>"

    assert Extractor.extract(html) == %{title: "My Page \t Title", hrefs: []}
  end

  test "returns a well-formed empty extraction for invalid UTF-8 garbage bytes" do
    # These leading bytes cannot form valid UTF-8 code points.
    html = <<0xFF, 0xFE, 1, 2, 3>>

    assert Extractor.extract(html) == %{title: nil, hrefs: []}
  end

  test "returns an empty extraction for an empty string" do
    assert Extractor.extract("") == %{title: nil, hrefs: []}
  end

  test "preserves duplicate hrefs in document order" do
    html = """
    <a href="/duplicate">First occurrence</a>
    <a href="/between">Between</a>
    <a href="/duplicate">Second occurrence</a>
    """

    assert Extractor.extract(html) == %{
             title: nil,
             hrefs: ["/duplicate", "/between", "/duplicate"]
           }
  end

  test "extracts hrefs from anchors marked nofollow" do
    html = "<a href=\"/still-extracted\" rel=\"nofollow\">Follow policy is external</a>"

    assert Extractor.extract(html) == %{title: nil, hrefs: ["/still-extracted"]}
  end

  test "does not surface or apply a document base href" do
    html = """
    <html>
      <head>
        <title>Base handling</title>
        <base href="https://example.com/directory/">
      </head>
      <body><a href="relative-page">Relative page</a></body>
    </html>
    """

    result = Extractor.extract(html)

    assert result == %{title: "Base handling", hrefs: ["relative-page"]}
    refute Map.has_key?(result, :base)
  end
end
