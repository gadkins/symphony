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

    log_file
    |> rotated_files(max_files)
    |> Enum.flat_map(&read_lines/1)
    |> Enum.filter(&matches_issue?(&1, issue_identifier))
    |> Enum.take(-max_lines)
  end

  @spec follow_state(String.t(), keyword()) :: %{
          path: String.t(),
          offset: non_neg_integer(),
          issue_identifier: String.t(),
          partial: String.t()
        }
  def follow_state(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    path = log_file(opts)

    %{
      path: path,
      offset: file_size(path),
      issue_identifier: issue_identifier,
      partial: ""
    }
  end

  @spec poll(map()) :: {[String.t()], map()}
  def poll(%{path: path, offset: offset, issue_identifier: issue_identifier, partial: partial} = state) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, ^offset} = :file.position(file, offset)
          chunk =
            case IO.binread(file, :eof) do
              :eof -> ""
              data when is_binary(data) -> data
            end
          {:ok, new_offset} = :file.position(file, :cur)

          {complete, remainder} = split_with_partial(partial <> chunk)

          lines =
            complete
            |> Enum.filter(&matches_issue?(&1, issue_identifier))

          {lines, %{state | offset: new_offset, partial: remainder}}
        after
          File.close(file)
        end

      {:error, _} ->
        {[], state}
    end
  end

  defp matches_issue?(line, issue_identifier) do
    ~r/issue_identifier=#{Regex.escape(issue_identifier)}(\s|$)/
    |> Regex.match?(line)
  end

  defp rotated_files(log_file, max_files) do
    rotated =
      max_files..1//-1
      |> Enum.map(&"#{log_file}.#{&1}")
      |> Enum.filter(&File.regular?/1)

    rotated ++ [log_file]
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
end
