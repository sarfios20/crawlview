defmodule Crawlview.Stats do
  @moduledoc """
  Holds the counters and wall-clock timestamps for one crawl.
  """

  @type t :: %__MODULE__{
          visited: non_neg_integer(),
          queued: non_neg_integer(),
          in_flight: non_neg_integer(),
          ok: non_neg_integer(),
          broken: non_neg_integer(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil
        }

  @enforce_keys [:started_at]
  defstruct visited: 0,
            queued: 0,
            in_flight: 0,
            ok: 0,
            broken: 0,
            started_at: nil,
            finished_at: nil
end
