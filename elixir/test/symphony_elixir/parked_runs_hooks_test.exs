defmodule SymphonyElixir.ParkedRunsHooksTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
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
end
