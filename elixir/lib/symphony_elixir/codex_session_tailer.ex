defmodule SymphonyElixir.CodexSessionTailer do
  @moduledoc """
  Resolves Codex session JSONL files by session id and extracts readable transcript lines.
  """

  @default_sessions_root Path.expand("~/.codex/sessions")
  @raw_line_max_length 200
  @exec_cmd_pattern ~r/cmd:\s*"((?:\\.|[^"\\])*)"/

  @spec resolve_path(String.t() | nil, keyword()) ::
          {:ok, Path.t()} | {:error, :not_found | :invalid_session}
  def resolve_path(session_id, opts \\ [])

  def resolve_path(session_id, opts) when session_id in [nil, "n/a", ""] do
    _ = opts
    {:error, :invalid_session}
  end

  def resolve_path(session_id, opts) when is_binary(session_id) do
    root = Keyword.get(opts, :sessions_root, @default_sessions_root)

    case find_session_file(root, session_id) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @spec readable_lines(Path.t() | String.t(), keyword()) :: [String.t()]
  def readable_lines(path_or_session, opts \\ [])

  def readable_lines(path_or_session, opts) when is_binary(path_or_session) do
    case resolve_input_path(path_or_session, opts) do
      {:ok, path} -> path |> read_file_lines() |> Enum.flat_map(&format_line/1)
      {:error, _} -> []
    end
  end

  @spec follow_state(Path.t() | String.t(), keyword()) :: %{
          path: String.t(),
          offset: non_neg_integer(),
          partial: String.t()
        }
  def follow_state(path_or_session, opts \\ []) when is_binary(path_or_session) do
    case resolve_input_path(path_or_session, opts) do
      {:ok, path} ->
        %{
          path: path,
          offset: file_size(path),
          partial: ""
        }

      {:error, _} ->
        %{
          path: path_or_session,
          offset: 0,
          partial: ""
        }
    end
  end

  @spec poll(map()) :: {[String.t()], map()}
  def poll(%{path: path, offset: offset, partial: partial} = state) do
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
            |> Enum.flat_map(&format_line/1)

          {lines, %{state | offset: new_offset, partial: remainder}}
        after
          File.close(file)
        end

      {:error, _} ->
        {[], state}
    end
  end

  defp resolve_input_path(path_or_session, opts) do
    if File.regular?(path_or_session) do
      {:ok, path_or_session}
    else
      resolve_path(path_or_session, opts)
    end
  end

  defp find_session_file(root, session_id) do
    root
    |> Path.join("**/*#{session_id}*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort_by(&file_mtime/1, :desc)
    |> List.first()
  end

  defp read_file_lines(path) do
    case File.read(path) do
      {:ok, content} -> split_lines(content)
      {:error, _} -> []
    end
  end

  defp format_line(line) do
    line = String.trim(line)

    if line == "" do
      []
    else
      case Jason.decode(line) do
        {:ok, event} ->
          case readable_from_event(event) do
            nil -> []
            formatted -> [formatted]
          end

        {:error, _} ->
          [truncate_raw(line)]
      end
    end
  end

  defp readable_from_event(%{"type" => "event_msg", "payload" => payload}) when is_map(payload) do
    readable_from_payload(payload)
  end

  defp readable_from_event(%{"type" => "response_item", "payload" => payload}) when is_map(payload) do
    readable_from_response_item(payload)
  end

  defp readable_from_event(_event), do: nil

  defp readable_from_payload(%{"type" => "agent_message", "message" => message})
       when is_binary(message) and message != "" do
    "[message] #{message}"
  end

  defp readable_from_payload(%{"type" => "user_message", "message" => message})
       when is_binary(message) and message != "" do
    "[message] user: #{message}"
  end

  defp readable_from_payload(%{"type" => "patch_apply_end", "success" => success}) do
    status = if success, do: "succeeded", else: "failed"
    "[command] patch apply #{status}"
  end

  defp readable_from_payload(%{"type" => "token_count"}), do: nil
  defp readable_from_payload(%{"type" => "task_started"}), do: nil
  defp readable_from_payload(_payload), do: nil

  defp readable_from_response_item(%{
         "type" => "custom_tool_call",
         "name" => "exec",
         "input" => input
       })
       when is_binary(input) do
    case extract_exec_command(input) do
      nil -> nil
      command -> "[command] #{command}"
    end
  end

  defp readable_from_response_item(%{"type" => "message", "role" => "assistant", "content" => content})
       when is_list(content) do
    case extract_message_text(content) do
      nil -> nil
      text -> "[message] #{text}"
    end
  end

  defp readable_from_response_item(%{"type" => "reasoning"}), do: nil
  defp readable_from_response_item(%{"type" => "custom_tool_call_output"}), do: nil
  defp readable_from_response_item(%{"type" => "function_call"}), do: nil
  defp readable_from_response_item(%{"type" => "function_call_output"}), do: nil
  defp readable_from_response_item(_payload), do: nil

  defp extract_exec_command(input) do
    case Regex.run(@exec_cmd_pattern, input, capture: :all_but_first) do
      [command] -> unescape_json_string(command)
      _ -> nil
    end
  end

  defp extract_message_text(content) do
    content
    |> Enum.find_value(fn
      %{"type" => type, "text" => text} when type in ["output_text", "input_text"] and is_binary(text) ->
        text

      _ ->
        nil
    end)
  end

  defp unescape_json_string(string) do
    string
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp truncate_raw(line) do
    if String.length(line) <= @raw_line_max_length do
      line
    else
      String.slice(line, 0, @raw_line_max_length)
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
