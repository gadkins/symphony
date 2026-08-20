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
      identifier: "TEST-39",
      state: "Human Review"
    }

    assert :ok = ParkedRunsHooks.on_leave_active(issue, "sess-1", "/ws/TEST-39")

    assert %{
             issue_identifier: "TEST-39",
             session_id: "sess-1",
             workspace_path: "/ws/TEST-39",
             linear_state: "Human Review"
           } = ParkedRuns.get("TEST-39")
  end

  test "on_leave_active normalizes n/a session_id to nil" do
    issue = %Issue{id: "issue-2", identifier: "TEST-40", state: "Human Review"}

    assert :ok = ParkedRunsHooks.on_leave_active(issue, "n/a", nil)
    assert ParkedRuns.get("TEST-40").session_id == nil
  end

  test "on_terminal deletes parked run" do
    ParkedRuns.upsert(%{
      issue_identifier: "TEST-39",
      session_id: "sess-1",
      workspace_path: "/ws/TEST-39",
      linear_state: "Human Review"
    })

    assert :ok = ParkedRunsHooks.on_terminal("TEST-39")
    assert ParkedRuns.get("TEST-39") == nil
  end

  test "keep_parked_state? is true for Human Review and Merging" do
    assert ParkedRunsHooks.keep_parked_state?("Human Review")
    assert ParkedRunsHooks.keep_parked_state?("merging")
    refute ParkedRunsHooks.keep_parked_state?("In Progress")
    refute ParkedRunsHooks.keep_parked_state?("Done")
  end

  test "reconcile deletes terminal and active rework, keeps Human Review / Merging" do
    ParkedRuns.upsert(%{
      issue_identifier: "TEST-39",
      session_id: "s1",
      workspace_path: "/ws/TEST-39",
      linear_state: "Human Review"
    })

    ParkedRuns.upsert(%{
      issue_identifier: "TEST-40",
      session_id: "s2",
      workspace_path: "/ws/TEST-40",
      linear_state: "Merging"
    })

    ParkedRuns.upsert(%{
      issue_identifier: "TEST-41",
      session_id: "s3",
      workspace_path: "/ws/TEST-41",
      linear_state: "Human Review"
    })

    ParkedRuns.upsert(%{
      issue_identifier: "TEST-42",
      session_id: "s4",
      workspace_path: "/ws/TEST-42",
      linear_state: "Human Review"
    })

    ParkedRuns.upsert(%{
      issue_identifier: "TEST-43",
      session_id: "s5",
      workspace_path: "/ws/TEST-43",
      linear_state: "Human Review"
    })

    # Merging is often configured as an active state; keep_parked_state?/1 must win.
    issues_by_identifier = %{
      "TEST-39" => %Issue{id: "i39", identifier: "TEST-39", state: "Done"},
      "TEST-40" => %Issue{id: "i40", identifier: "TEST-40", state: "Merging"},
      "TEST-41" => %Issue{id: "i41", identifier: "TEST-41", state: "In Progress"},
      "TEST-43" => %Issue{id: "i43", identifier: "TEST-43", state: "Rework"}
      # TEST-42 unknown omitted → keep
    }

    active = MapSet.new(["todo", "in progress", "merging", "rework"])
    terminal = MapSet.new(["done", "canceled"])

    assert :ok = ParkedRunsHooks.reconcile(ParkedRuns.list(), issues_by_identifier, active, terminal)

    assert ParkedRuns.get("TEST-39") == nil
    assert ParkedRuns.get("TEST-41") == nil
    assert ParkedRuns.get("TEST-43") == nil
    assert ParkedRuns.get("TEST-40").linear_state == "Merging"
    assert ParkedRuns.get("TEST-42").linear_state == "Human Review"
  end

  test "retry leave-active parks Human Review with session metadata" do
    issue = %Issue{
      id: "issue-hr",
      identifier: "TEST-50",
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
        identifier: "TEST-50",
        session_id: "sess-hr",
        workspace_path: "/ws/TEST-50"
      })

    assert %{
             issue_identifier: "TEST-50",
             session_id: "sess-hr",
             workspace_path: "/ws/TEST-50",
             linear_state: "Human Review"
           } = ParkedRuns.get("TEST-50")
  end

  test "retry does not park still-active unroutable issues" do
    issue = %Issue{
      id: "issue-active",
      identifier: "TEST-51",
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
        identifier: "TEST-51",
        session_id: "sess-active",
        workspace_path: "/ws/TEST-51"
      })

    assert ParkedRuns.get("TEST-51") == nil
  end

  test "retry terminal clears parked entry" do
    ParkedRuns.upsert(%{
      issue_identifier: "TEST-52",
      session_id: "sess-done",
      workspace_path: "/ws/TEST-52",
      linear_state: "Human Review"
    })

    issue = %Issue{
      id: "issue-done",
      identifier: "TEST-52",
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
        identifier: "TEST-52",
        workspace_path: "/ws/TEST-52"
      })

    assert ParkedRuns.get("TEST-52") == nil
  end
end
