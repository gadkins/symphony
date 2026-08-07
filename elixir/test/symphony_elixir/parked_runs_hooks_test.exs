defmodule SymphonyElixir.ParkedRunsHooksTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.ParkedRuns
  alias SymphonyElixir.ParkedRunsHooks

  setup do
    tmp = Path.join(System.tmp_dir!(), "parked-runs-hooks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "log"))
    log_file = Path.join(tmp, "log/symphony.log")
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, log_file)

    stop_application_parked_runs()
    start_supervised!({ParkedRuns, []})

    on_exit(fn ->
      if pid = Process.whereis(ParkedRuns), do: GenServer.stop(pid)
      restore_log_file_env(previous_log_file)
      restart_application_parked_runs()
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp stop_application_parked_runs do
    if Process.whereis(ParkedRuns) do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ParkedRuns)
    end
  end

  defp restart_application_parked_runs do
    case Supervisor.restart_child(SymphonyElixir.Supervisor, ParkedRuns) do
      {:ok, _pid} -> :ok
      {:error, :not_found} -> :ok
      other -> raise "failed to restart ParkedRuns: #{inspect(other)}"
    end
  end

  defp restore_log_file_env(nil), do: Application.delete_env(:symphony_elixir, :log_file)

  defp restore_log_file_env(log_file) do
    Application.put_env(:symphony_elixir, :log_file, log_file)
  end

  test "on_leave_active upserts parked run from issue metadata" do
    issue = %Issue{
      id: "issue-1",
      identifier: "FIL-39",
      state: "Human Review"
    }

    assert :ok = ParkedRunsHooks.on_leave_active(issue, "sess-1", "/ws/FIL-39")

    assert %{
             issue_identifier: "FIL-39",
             session_id: "sess-1",
             workspace_path: "/ws/FIL-39",
             linear_state: "Human Review"
           } = ParkedRuns.get("FIL-39")
  end

  test "on_leave_active normalizes n/a session_id to nil" do
    issue = %Issue{id: "issue-2", identifier: "FIL-40", state: "Human Review"}

    assert :ok = ParkedRunsHooks.on_leave_active(issue, "n/a", nil)
    assert ParkedRuns.get("FIL-40").session_id == nil
  end

  test "on_terminal deletes parked run" do
    ParkedRuns.upsert(%{
      issue_identifier: "FIL-39",
      session_id: "sess-1",
      workspace_path: "/ws/FIL-39",
      linear_state: "Human Review"
    })

    assert :ok = ParkedRunsHooks.on_terminal("FIL-39")
    assert ParkedRuns.get("FIL-39") == nil
  end

  test "reconcile deletes terminal and active rework, keeps Human Review / Merging" do
    ParkedRuns.upsert(%{
      issue_identifier: "FIL-39",
      session_id: "s1",
      workspace_path: "/ws/FIL-39",
      linear_state: "Human Review"
    })

    ParkedRuns.upsert(%{
      issue_identifier: "FIL-40",
      session_id: "s2",
      workspace_path: "/ws/FIL-40",
      linear_state: "Merging"
    })

    ParkedRuns.upsert(%{
      issue_identifier: "FIL-41",
      session_id: "s3",
      workspace_path: "/ws/FIL-41",
      linear_state: "Human Review"
    })

    ParkedRuns.upsert(%{
      issue_identifier: "FIL-42",
      session_id: "s4",
      workspace_path: "/ws/FIL-42",
      linear_state: "Human Review"
    })

    issues_by_identifier = %{
      "FIL-39" => %Issue{id: "i39", identifier: "FIL-39", state: "Done"},
      "FIL-41" => %Issue{id: "i41", identifier: "FIL-41", state: "In Progress"}
      # FIL-40 Merging and FIL-42 unknown omitted → keep
    }

    active = MapSet.new(["todo", "in progress"])
    terminal = MapSet.new(["done", "canceled"])

    assert :ok = ParkedRunsHooks.reconcile(ParkedRuns.list(), issues_by_identifier, active, terminal)

    assert ParkedRuns.get("FIL-39") == nil
    assert ParkedRuns.get("FIL-41") == nil
    assert ParkedRuns.get("FIL-40").linear_state == "Merging"
    assert ParkedRuns.get("FIL-42").linear_state == "Human Review"
  end

  test "retry leave-active parks Human Review with session metadata" do
    issue = %Issue{
      id: "issue-hr",
      identifier: "FIL-50",
      title: "Parked after agent exit",
      state: "Human Review",
      labels: []
    }

    state = %Orchestrator.State{
      claimed: MapSet.new(["issue-hr"]),
      retry_attempts: %{}
    }

    _updated =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, "issue-hr", 1, %{
        identifier: "FIL-50",
        session_id: "sess-hr",
        workspace_path: "/ws/FIL-50"
      })

    assert %{
             issue_identifier: "FIL-50",
             session_id: "sess-hr",
             workspace_path: "/ws/FIL-50",
             linear_state: "Human Review"
           } = ParkedRuns.get("FIL-50")
  end

  test "retry does not park still-active unroutable issues" do
    issue = %Issue{
      id: "issue-active",
      identifier: "FIL-51",
      title: "Still active",
      state: "In Progress",
      labels: []
    }

    state = %Orchestrator.State{
      claimed: MapSet.new(["issue-active"]),
      retry_attempts: %{}
    }

    _updated =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, "issue-active", 1, %{
        identifier: "FIL-51",
        session_id: "sess-active",
        workspace_path: "/ws/FIL-51"
      })

    assert ParkedRuns.get("FIL-51") == nil
  end

  test "retry terminal clears parked entry" do
    ParkedRuns.upsert(%{
      issue_identifier: "FIL-52",
      session_id: "sess-done",
      workspace_path: "/ws/FIL-52",
      linear_state: "Human Review"
    })

    issue = %Issue{
      id: "issue-done",
      identifier: "FIL-52",
      title: "Done",
      state: "Done",
      labels: []
    }

    state = %Orchestrator.State{
      claimed: MapSet.new(["issue-done"]),
      retry_attempts: %{}
    }

    _updated =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, "issue-done", 1, %{
        identifier: "FIL-52",
        workspace_path: "/ws/FIL-52"
      })

    assert ParkedRuns.get("FIL-52") == nil
  end
end
