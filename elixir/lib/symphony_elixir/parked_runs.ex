defmodule SymphonyElixir.ParkedRuns do
  @moduledoc """
  Persists parked-run metadata as JSON next to the engine log file.
  """

  use GenServer

  alias SymphonyElixir.LogFile

  @entry_keys [:issue_identifier, :session_id, :workspace_path, :linear_state, :parked_at]

  defmodule State do
    @moduledoc false

    defstruct runs: %{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec upsert(%{
          issue_identifier: String.t(),
          session_id: String.t() | nil,
          workspace_path: String.t() | nil,
          linear_state: String.t() | nil
        }) :: :ok
  def upsert(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:upsert, normalize_attrs(attrs)})
  end

  @spec delete(String.t()) :: :ok
  def delete(issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(__MODULE__, {:delete, issue_identifier})
  end

  @spec get(String.t()) :: map() | nil
  def get(issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(__MODULE__, {:get, issue_identifier})
  end

  @spec list() :: [map()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @impl true
  def init(_opts) do
    {:ok, %State{runs: load_runs()}}
  end

  @impl true
  def handle_call({:upsert, attrs}, _from, %State{runs: runs} = state) do
    issue_identifier = attrs.issue_identifier

    entry =
      runs
      |> Map.get(issue_identifier, %{})
      |> Map.merge(attrs)
      |> Map.put(:parked_at, DateTime.utc_now(:second))

    new_runs = Map.put(runs, issue_identifier, entry)
    :ok = persist(new_runs)
    {:reply, :ok, %{state | runs: new_runs}}
  end

  def handle_call({:delete, issue_identifier}, _from, %State{runs: runs} = state) do
    new_runs = Map.delete(runs, issue_identifier)
    :ok = persist(new_runs)
    {:reply, :ok, %{state | runs: new_runs}}
  end

  def handle_call({:get, issue_identifier}, _from, %State{runs: runs} = state) do
    {:reply, Map.get(runs, issue_identifier), state}
  end

  def handle_call(:list, _from, %State{runs: runs} = state) do
    list =
      runs
      |> Map.values()
      |> Enum.sort_by(& &1.issue_identifier)

    {:reply, list, state}
  end

  defp normalize_attrs(%{issue_identifier: issue_identifier} = attrs) do
    %{
      issue_identifier: issue_identifier,
      session_id: normalize_session_id(Map.get(attrs, :session_id)),
      workspace_path: Map.get(attrs, :workspace_path),
      linear_state: Map.get(attrs, :linear_state)
    }
  end

  defp normalize_session_id("n/a"), do: nil
  defp normalize_session_id(session_id), do: session_id

  defp persist_path do
    log_file = Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    Path.join(Path.dirname(log_file), "parked_runs.json")
  end

  defp load_runs do
    path = persist_path()

    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> decode_runs()
    else
      %{}
    end
  end

  defp decode_runs(%{} = decoded) do
    Enum.into(decoded, %{}, fn {issue_identifier, entry} ->
      {issue_identifier, atomize_entry(entry)}
    end)
  end

  defp atomize_entry(entry) when is_map(entry) do
    Enum.reduce(@entry_keys, %{}, fn key, acc ->
      string_key = Atom.to_string(key)

      value =
        cond do
          Map.has_key?(entry, string_key) -> Map.fetch!(entry, string_key)
          Map.has_key?(entry, key) -> Map.fetch!(entry, key)
          true -> :missing
        end

      case value do
        :missing -> acc
        value -> Map.put(acc, key, decode_entry_value(key, value))
      end
    end)
  end

  defp decode_entry_value(:parked_at, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp decode_entry_value(_key, value), do: value

  defp persist(%{} = runs) do
    path = persist_path()
    :ok = File.mkdir_p(Path.dirname(path))

    encoded =
      runs
      |> Enum.into(%{}, fn {_id, entry} ->
        {entry.issue_identifier, encode_entry(entry)}
      end)
      |> Jason.encode!(pretty: true)

    tmp = path <> ".tmp"
    :ok = File.write(tmp, encoded)
    :ok = File.rename(tmp, path)
    :ok
  end

  defp encode_entry(entry) do
    entry
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key), encode_entry_value(key, value)}
    end)
  end

  defp encode_entry_value(:parked_at, %DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_entry_value(_key, value), do: value
end
