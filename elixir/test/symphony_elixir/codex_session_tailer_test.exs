defmodule SymphonyElixir.CodexSessionTailerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodexSessionTailer

  @session_id "019fd785-dab2-7a51-a955-2de2fe598dcd"

  setup do
    tmp = Path.join(System.tmp_dir!(), "codex-session-tailer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{root: tmp}
  end

  test "resolve_path returns invalid_session for nil and n/a" do
    assert {:error, :invalid_session} = CodexSessionTailer.resolve_path(nil)
    assert {:error, :invalid_session} = CodexSessionTailer.resolve_path("n/a")
  end

  test "resolve_path returns not_found when session file missing", %{root: root} do
    assert {:error, :not_found} =
             CodexSessionTailer.resolve_path(@session_id, sessions_root: root)
  end

  test "resolves rollout file containing session id", %{root: root} do
    path =
      Path.join([
        root,
        "2026/08/06",
        "rollout-2026-08-06T09-41-41-#{@session_id}.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}\n")

    assert {:ok, ^path} = CodexSessionTailer.resolve_path(@session_id, sessions_root: root)
  end

  test "resolves rollout file from Symphony thread-turn session id", %{root: root} do
    thread_id = "01a000bf-0cd9-7b00-9d5e-d7902d7a7790"
    turn_id = "01a000bf-0d5e-7712-8e37-b1278e71476f"
    session_id = "#{thread_id}-#{turn_id}"

    path =
      Path.join([
        root,
        "2026/08/14",
        "rollout-2026-08-14T09-48-35-#{thread_id}.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}\n")

    assert {:ok, ^path} = CodexSessionTailer.resolve_path(session_id, sessions_root: root)
  end

  test "readable_lines extracts agent message text from jsonl", %{root: root} do
    path =
      write_session!(root, [
        Jason.encode!(%{
          "type" => "event_msg",
          "payload" => %{
            "type" => "agent_message",
            "message" => "Planning the implementation steps."
          }
        }),
        Jason.encode!(%{
          "type" => "event_msg",
          "payload" => %{
            "type" => "token_count",
            "info" => %{"total_token_usage" => %{"total_tokens" => 42}}
          }
        }),
        Jason.encode!(%{
          "type" => "response_item",
          "payload" => %{
            "type" => "custom_tool_call",
            "name" => "exec",
            "status" => "completed",
            "input" => "const r = await tools.exec_command({cmd:\"git status --short\",workdir:\"/tmp\"});"
          }
        })
      ])

    lines = CodexSessionTailer.readable_lines(path)

    assert lines == [
             "[message] Planning the implementation steps.",
             "[command] git status --short"
           ]
  end

  test "readable_lines surfaces reasoning, tools, and command output", %{root: root} do
    path =
      write_session!(root, [
        Jason.encode!(%{
          "type" => "response_item",
          "payload" => %{
            "type" => "reasoning",
            "id" => "rs_020c455b4abcd"
          }
        }),
        Jason.encode!(%{
          "type" => "response_item",
          "payload" => %{
            "type" => "function_call",
            "id" => "fc_01170a31dd3e",
            "name" => "wait"
          }
        }),
        Jason.encode!(%{
          "type" => "response_item",
          "payload" => %{
            "type" => "custom_tool_call_output",
            "output" => [
              %{"type" => "input_text", "text" => "> @example/contract@1.0.0 build > tsc -p tsconfig.json\n"}
            ]
          }
        }),
        Jason.encode!(%{
          "type" => "event_msg",
          "payload" => %{
            "type" => "sub_agent_activity",
            "kind" => "started",
            "agent_path" => "/root/skill_product_mode"
          }
        })
      ])

    lines = CodexSessionTailer.readable_lines(path)

    assert lines == [
             "item started: reasoning (rs_020c455b4)",
             "item started: wait (fc_01170a31d)",
             "command output streaming: > @example/contract@1.0.0 build > tsc -p tsconfig.json",
             "[sub-agent] started /root/skill_product_mode"
           ]
  end

  test "readable_lines resolves session id via sessions_root", %{root: root} do
    path =
      Path.join([
        root,
        "2026/08/06",
        "rollout-2026-08-06T09-41-41-#{@session_id}.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "type" => "event_msg",
        "payload" => %{"type" => "agent_message", "message" => "Hello from session."}
      }) <> "\n"
    )

    assert CodexSessionTailer.readable_lines(@session_id, sessions_root: root) == [
             "[message] Hello from session."
           ]
  end

  test "readable_lines includes truncated raw line on parse failure", %{root: root} do
    raw = String.duplicate("x", 300)
    path = write_session!(root, [raw])

    [line] = CodexSessionTailer.readable_lines(path)
    assert String.starts_with?(line, raw |> String.slice(0, 200))
    assert String.length(line) <= 200
  end

  test "poll returns newly appended readable lines", %{root: root} do
    path = write_session!(root, [])

    state = CodexSessionTailer.follow_state(path)

    File.write!(
      path,
      Jason.encode!(%{
        "type" => "event_msg",
        "payload" => %{"type" => "agent_message", "message" => "Late update."}
      }) <> "\n",
      [:append]
    )

    {lines, new_state} = CodexSessionTailer.poll(state)
    assert lines == ["[message] Late update."]
    assert new_state.offset > state.offset

    {more, _} = CodexSessionTailer.poll(new_state)
    assert more == []
  end

  defp write_session!(root, lines) do
    path =
      Path.join([
        root,
        "2026/08/06",
        "rollout-2026-08-06T09-41-41-#{@session_id}.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> if(lines == [], do: "", else: "\n"))
    path
  end
end
