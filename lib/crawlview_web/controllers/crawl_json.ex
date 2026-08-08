defmodule CrawlviewWeb.CrawlJSON do
  @moduledoc """
  Transforms crawler snapshots into the stable JSON wire representation.

  The domain keeps Elixir-native structs and atoms; this boundary deliberately
  publishes snake_case fields, string enum values, UTC ISO 8601 timestamps, and
  JSON nulls. These names follow the domain vocabulary and are the versioning
  contract clients may rely on.
  """

  alias Crawlview.{Crawl, Page, Stats}

  @spec created(%{id: String.t()}) :: map()
  def created(%{id: id}), do: %{id: id}

  @spec show(%{state: Crawl.State.t()}) :: map()
  def show(%{state: state}), do: crawl(state)

  @spec pages(%{
          pages: [Page.t()],
          offset: non_neg_integer(),
          limit: pos_integer(),
          total: non_neg_integer()
        }) :: map()
  def pages(%{pages: pages, offset: offset, limit: limit, total: total}) do
    returned = length(pages)

    %{
      pages: Enum.map(pages, &page/1),
      pagination: %{
        offset: offset,
        limit: limit,
        returned: returned,
        total: total,
        has_more: offset + returned < total
      }
    }
  end

  @spec error(%{reason: atom()}) :: map()
  def error(%{reason: reason}) do
    {code, message} = error_details(reason)
    %{error: %{code: code, message: message}}
  end

  @spec crawl(Crawl.State.t()) :: map()
  def crawl(%Crawl.State{} = state) do
    %{
      id: state.id,
      root_url: state.root_url,
      status: atom_string(state.status),
      finished_reason: atom_string(state.finished_reason),
      stats: stats(state.stats)
    }
  end

  @spec page(Page.t()) :: map()
  def page(%Page{} = page) do
    %{
      url: page.url,
      depth: page.depth,
      referrer: page.referrer,
      outcome: atom_string(page.outcome),
      status: page.status,
      title: page.title,
      links: page.links,
      duration_ms: page.duration_ms
    }
  end

  @spec stats(Stats.t()) :: map()
  def stats(%Stats{} = stats) do
    %{
      visited: stats.visited,
      queued: stats.queued,
      in_flight: stats.in_flight,
      ok: stats.ok,
      broken: stats.broken,
      started_at: timestamp(stats.started_at),
      finished_at: timestamp(stats.finished_at)
    }
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)

  defp timestamp(nil), do: nil

  defp timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp error_details(:invalid_scheme),
    do: {"invalid_scheme", "Use an address beginning with http:// or https://."}

  defp error_details(:invalid_url),
    do: {"invalid_url", "Enter a complete, valid website address."}

  defp error_details(:unresolvable),
    do: {"unresolvable", "That address did not resolve."}

  defp error_details(:private_address),
    do: {"private_address", "That address points to a private or reserved network."}

  defp error_details(:not_found),
    do: {"not_found", "That crawl does not exist or is no longer available."}

  defp error_details(:rate_limited),
    do: {"rate_limited", "You have started several crawls already. Try again in a minute."}

  defp error_details(:at_capacity),
    do: {"at_capacity", "Too many crawls are running right now. Try again in half a minute."}
end
