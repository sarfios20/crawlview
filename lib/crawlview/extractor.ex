defmodule Crawlview.Extractor do
  @moduledoc """
  Extracts the document title and anchor href attributes from HTML.

  Parsing is best-effort: input that cannot be parsed is represented by an empty
  extraction rather than an error that callers must handle.
  """

  @empty_result %{title: nil, hrefs: []}

  @spec extract(html :: binary()) :: %{title: String.t() | nil, hrefs: [String.t()]}
  def extract(html) do
    try do
      case Floki.parse_document(html) do
        {:ok, tree} ->
          %{title: extract_title(tree), hrefs: extract_hrefs(tree)}

        {:error, _reason} ->
          @empty_result
      end
    rescue
      _exception -> @empty_result
    catch
      _kind, _reason -> @empty_result
    end
  end

  defp extract_title(tree) do
    title =
      tree
      |> Floki.find("title")
      |> Floki.text()
      |> String.trim()

    if title == "", do: nil, else: title
  end

  defp extract_hrefs(tree) do
    # Order and multiplicity describe the source document, so duplicate hrefs stay
    # here; deduplication is a crawl/URL-layer concern.
    # `rel="nofollow"` is deliberately ignored because following policy belongs to
    # the crawl layer, while this module only reports attributes present in the HTML.
    # A document's <base href> is neither surfaced nor applied: the design supplies
    # base externally to the URL layer, and exposing it here would widen this
    # interface while duplicating a concern already owned there.
    tree
    |> Floki.find("a")
    |> Enum.reduce([], fn {_tag, attributes, _children}, hrefs ->
      case Enum.find(attributes, fn {name, _value} -> href_attribute?(name) end) do
        {_name, value} when is_binary(value) -> [value | hrefs]
        _missing_or_invalid -> hrefs
      end
    end)
    |> Enum.reverse()
  end

  defp href_attribute?(<<h, r, e, f>>)
       when h in [?h, ?H] and r in [?r, ?R] and e in [?e, ?E] and f in [?f, ?F],
       do: true

  defp href_attribute?(_name), do: false
end
