defmodule Crawlview.Page do
  @moduledoc """
  Describes the result of visiting one normalized URL in a crawl.
  """

  @type t :: %__MODULE__{
          url: String.t(),
          depth: non_neg_integer(),
          referrer: String.t() | nil,
          outcome: atom(),
          status: pos_integer() | nil,
          title: String.t() | nil,
          links: [String.t()],
          duration_ms: non_neg_integer()
        }

  @enforce_keys [:url, :depth, :referrer, :outcome, :status, :title, :links, :duration_ms]
  defstruct url: nil,
            depth: 0,
            referrer: nil,
            outcome: nil,
            status: nil,
            title: nil,
            links: [],
            duration_ms: 0
end
