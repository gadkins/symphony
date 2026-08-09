defmodule SymphonyElixir.EngineLogTailerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.EngineLogTailer

  setup do
    tmp = Path.join(System.tmp_dir!(), "engine-log-tailer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "filters by issue_identifier and returns last max_lines", %{tmp: tmp} do
    log = write_log!(tmp, [
      "info: other issue_identifier=FIL-1\n",
      "info: Dispatching issue_identifier=FIL-39 pid=1\n",
      "info: Codex session started issue_identifier=FIL-39 session_id=abc\n"
    ])

    lines = EngineLogTailer.initial_lines("FIL-39", log_file: log, max_lines: 500)
    assert length(lines) == 2
    assert Enum.all?(lines, &String.contains?(&1, "FIL-39"))
  end

  test "boundary-safe match avoids prefix collisions", %{tmp: tmp} do
    log = write_log!(tmp, [
      "info: Dispatching issue_identifier=FIL-3 pid=1\n",
      "info: Dispatching issue_identifier=FIL-39 pid=2\n"
    ])

    lines = EngineLogTailer.initial_lines("FIL-3", log_file: log)
    assert lines == ["info: Dispatching issue_identifier=FIL-3 pid=1"]
  end

  test "respects max_lines cap", %{tmp: tmp} do
    entries =
      for n <- 1..10 do
        "info: tick issue_identifier=FIL-39 n=#{n}\n"
      end

    log = write_log!(tmp, entries)
    lines = EngineLogTailer.initial_lines("FIL-39", log_file: log, max_lines: 3)
    assert length(lines) == 3
    assert List.last(lines) == "info: tick issue_identifier=FIL-39 n=10"
  end

  test "poll returns only new matching bytes", %{tmp: tmp} do
    log = write_log!(tmp, ["info: start issue_identifier=FIL-39\n"])

    state = EngineLogTailer.follow_state("FIL-39", log_file: log)
    assert state.offset == byte_size("info: start issue_identifier=FIL-39\n")

    File.write!(log, "info: new issue_identifier=FIL-39\n", [:append])
    File.write!(log, "info: other issue_identifier=FIL-1\n", [:append])

    {lines, new_state} = EngineLogTailer.poll(state)
    assert lines == ["info: new issue_identifier=FIL-39"]
    assert new_state.offset > state.offset

    {more, _} = EngineLogTailer.poll(new_state)
    assert more == []
  end

  test "scans rotated symphony.log.1 when present", %{tmp: tmp} do
    log = Path.join(tmp, "symphony.log")
    rotated = "#{log}.1"

    File.write!(rotated, "info: old issue_identifier=FIL-39 from-rotated\n")
    File.write!(log, "info: new issue_identifier=FIL-39 from-active\n")

    lines = EngineLogTailer.initial_lines("FIL-39", log_file: log)
    assert lines == [
             "info: old issue_identifier=FIL-39 from-rotated",
             "info: new issue_identifier=FIL-39 from-active"
           ]
  end

  defp write_log!(tmp, lines) do
    log = Path.join(tmp, "symphony.log")
    File.write!(log, IO.iodata_to_binary(lines))
    log
  end
end
