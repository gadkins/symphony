defmodule SymphonyElixir.EngineLogTailer do
  @moduledoc """
  Reads and tails Symphony engine logs filtered by issue identifier.
  """

  alias SymphonyElixir.LogFile

  @default_max_lines 500
  @default_max_files 5

  @spec initial_lines(String.t(), keyword()) :: [String.t()]
  def initial_lines(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    log_file = log_file(opts)
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)
    pattern = issue_pattern(issue_identifier)

    log_file
    |> rotated_files(max_files)
    |> Enum.flat_map(&read_lines/1)
    |> Enum.filter(&matches_issue?(&1, pattern))
    |> Enum.take(-max_lines)
  end

  @spec follow_state(String.t(), keyword()) :: %{
          path: String.t(),
          base_path: String.t(),
          offset: non_neg_integer(),
          issue_identifier: String.t(),
          partial: String.t()
        }
  def follow_state(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    base_path = log_file(opts)
    path = active_log_path(base_path)

    %{
      path: path,
      base_path: base_path,
      offset: file_size(path),
      issue_identifier: issue_identifier,
      partial: ""
    }
  end

  @spec poll(map()) :: {[String.t()], map()}
  def poll(%{issue_identifier: issue_identifier} = state) do
    pattern = issue_pattern(issue_identifier)
    base_path = Map.get(state, :base_path, state.path)
    active = active_log_path(base_path)

    {drained, state} = drain_if_rotated(state, active, pattern)
    {lines, state} = read_matching(state, pattern)
    {drained ++ lines, state}
  end

  defp drain_if_rotated(%{path: path} = state, active, pattern) when path != active do
    {lines, _stale} = read_matching(state, pattern)
    {lines, %{state | path: active, offset: 0, partial: ""}}
  end

  defp drain_if_rotated(state, _active, _pattern), do: {[], state}

  defp read_matching(%{path: path, offset: offset, partial: partial} = state, pattern) do
    size = file_size(path)
    offset = if size < offset, do: 0, else: offset

    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, _} = :file.position(file, offset)

          chunk =
            case IO.binread(file, :eof) do
              :eof -> ""
              data when is_binary(data) -> data
            end

          {:ok, new_offset} = :file.position(file, :cur)
          {complete, remainder} = split_with_partial(partial <> chunk)

          lines =
            complete
            |> Enum.filter(&matches_issue?(&1, pattern))

          {lines, %{state | offset: new_offset, partial: remainder}}
        after
          File.close(file)
        end

      {:error, _} ->
        {[], state}
    end
  end

  defp issue_pattern(issue_identifier) do
    ~r/issue_identifier=#{Regex.escape(issue_identifier)}(\s|$)/
  end

  defp matches_issue?(line, %Regex{} = pattern) do
    Regex.match?(pattern, line)
  end

  defp rotated_files(log_file, max_files) do
    wrap =
      log_file
      |> wrap_segments(max_files)
      |> Enum.sort_by(fn {path, n} -> {file_mtime(path), n} end)
      |> Enum.map(&elem(&1, 0))

    if File.regular?(log_file) do
      wrap ++ [log_file]
    else
      wrap
    end
  end

  defp active_log_path(log_file) do
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)

    case wrap_segments(log_file, max_files) do
      [] ->
        log_file

      segments ->
        {path, _} = Enum.max_by(segments, fn {path, n} -> {file_mtime(path), n} end)
        path
    end
  end

  defp wrap_segments(log_file, max_files) do
    1..max_files
    |> Enum.map(fn n -> {"#{log_file}.#{n}", n} end)
    |> Enum.filter(fn {path, _} -> File.regular?(path) end)
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, content} -> split_lines(content)
      {:error, _} -> []
    end
  end

  defp split_lines(content) do
    content
    |> String.split("\n")
    |> case do
      [""] -> []
      lines -> lines
    end
  end

  defp split_with_partial(content) do
    case String.split(content, "\n", parts: :infinity) do
      [] ->
        {[], ""}

      [line] ->
        {[], line}

      lines ->
        {complete, [remainder]} = Enum.split(lines, -1)

        if String.ends_with?(content, "\n") do
          {complete ++ [remainder], ""}
        else
          {complete, remainder}
        end
    end
  end

  defp log_file(opts) do
    Keyword.get_lazy(opts, :log_file, fn ->
      Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    end)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _} -> 0
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end
end
