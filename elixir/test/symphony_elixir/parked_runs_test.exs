defmodule SymphonyElixir.ParkedRunsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{LogFile, ParkedRuns}

  setup do
    tmp = Path.join(System.tmp_dir!(), "parked-runs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "log"))
    log_file = Path.join(tmp, "log/symphony.log")
    Application.put_env(:symphony_elixir, :log_file, log_file)

    stop_application_parked_runs()
    start_supervised!({ParkedRuns, []})
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp, log_file: log_file}
  end

  defp stop_application_parked_runs do
    if Process.whereis(ParkedRuns) do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ParkedRuns)
    end
  end

  test "upserts, lists, and persists across process restart", %{tmp: tmp, log_file: log_file} do
    assert :ok =
             ParkedRuns.upsert(%{
               issue_identifier: "FIL-39",
               session_id: "sess-1",
               workspace_path: "/ws/FIL-39",
               linear_state: "Human Review"
             })

    assert [%{issue_identifier: "FIL-39", session_id: "sess-1"}] = ParkedRuns.list()

    persist = Path.join(Path.dirname(log_file), "parked_runs.json")
    assert File.exists?(persist)

    :ok = stop_supervised(ParkedRuns)
    start_supervised!({ParkedRuns, []})
    assert ParkedRuns.get("FIL-39").session_id == "sess-1"
  end

  test "delete removes entry and updates JSON" do
    ParkedRuns.upsert(%{issue_identifier: "FIL-39", session_id: "s", workspace_path: nil, linear_state: "Human Review"})
    assert :ok = ParkedRuns.delete("FIL-39")
    assert ParkedRuns.list() == []
  end
end
