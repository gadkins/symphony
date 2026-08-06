defmodule SymphonyElixir.ParkedRunsHooks do
  @moduledoc """
  Orchestrator hooks that park runs on leave-active and clear them on terminal.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ParkedRuns

  @spec on_leave_active(Issue.t(), String.t() | nil, String.t() | nil) :: :ok
  def on_leave_active(%Issue{} = issue, session_id, workspace_path) do
    ParkedRuns.upsert(%{
      issue_identifier: issue.identifier,
      session_id: normalize_session_id(session_id),
      workspace_path: workspace_path,
      linear_state: issue.state
    })
  end

  @spec on_terminal(String.t()) :: :ok
  def on_terminal(issue_identifier) when is_binary(issue_identifier) do
    ParkedRuns.delete(issue_identifier)
  end

  defp normalize_session_id(id) when id in [nil, "", "n/a"], do: nil
  defp normalize_session_id(id) when is_binary(id), do: id
end
