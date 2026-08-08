defmodule Crawlview.Crawl do
  @moduledoc """
  Starts, observes, and stops isolated in-memory website crawls.

  This is the crawler's complete public interface. Frontier management,
  deduplication, scheduling, policy enforcement, and process names remain
  private to this boundary.
  """

  alias Crawlview.Crawl.Server

  @supervisor Crawlview.Crawl.Supervisor
  @registry Crawlview.Crawl.Registry

  defmodule State do
    @moduledoc """
    A point-in-time, read-only view of a crawl.
    """

    @type t :: %__MODULE__{
            id: String.t(),
            root_url: String.t(),
            status: :running | :finished,
            pages: %{String.t() => Crawlview.Page.t()},
            stats: Crawlview.Stats.t(),
            finished_reason: nil | :completed | :stopped | :page_limit | :time_limit | :disallowed
          }

    @enforce_keys [:id, :root_url, :status, :pages, :stats, :finished_reason]
    defstruct id: nil,
              root_url: nil,
              status: :running,
              pages: %{},
              stats: nil,
              finished_reason: nil
  end

  @doc """
  Validates `url`, starts a crawl, and returns its opaque identifier.
  """
  @spec start(url :: String.t(), opts :: keyword()) ::
          {:ok, id :: String.t()} | {:error, atom()}
  def start(url, opts \\ []) do
    with {:ok, root_url} <- Crawlview.Url.public_http_url(url) do
      start_server(root_url, opts)
    end
  end

  @doc """
  Subscribes the caller to domain events for `id`.
  """
  @spec subscribe(id :: String.t()) :: :ok
  def subscribe(id) do
    :ok = Phoenix.PubSub.subscribe(Crawlview.PubSub, topic(id))
  end

  @doc """
  Returns the latest crawl state, or `:not_found` when no process owns `id`.
  """
  @spec snapshot(id :: String.t()) :: {:ok, State.t()} | :not_found
  def snapshot(id) do
    case lookup(id) do
      {:ok, server} -> safe_snapshot(server)
      :not_found -> :not_found
    end
  end

  @doc """
  Ensures that `id` is no longer running.
  """
  @spec stop(id :: String.t()) :: :ok
  def stop(id) do
    case lookup(id) do
      {:ok, server} -> GenServer.cast(server, :stop)
      :not_found -> :ok
    end

    :ok
  end

  defp start_server(root_url, opts) do
    id = random_id()

    case DynamicSupervisor.start_child(@supervisor, {Server, {id, root_url, opts}}) do
      {:ok, _server} -> {:ok, id}
      {:error, {:already_started, _server}} -> start_server(root_url, opts)
      {:error, reason} -> raise "could not start crawl server: #{inspect(reason)}"
    end
  end

  defp lookup(id) do
    case Registry.lookup(@registry, id) do
      [{server, _value}] -> {:ok, server}
      [] -> :not_found
    end
  end

  defp safe_snapshot(server) do
    {:ok, GenServer.call(server, :snapshot)}
  catch
    :exit, _reason -> :not_found
  end

  defp topic(id), do: "crawl:" <> id

  defp random_id do
    9
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
