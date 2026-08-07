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

  @doc """
  Drop parked entries that are terminal or back in an active state.
  Keep Human Review / Merging / unknown (not present in `issues_by_identifier`).
  """
  @spec reconcile([map()], %{optional(String.t()) => Issue.t()}, MapSet.t(), MapSet.t()) :: :ok
  def reconcile(parked_entries, issues_by_identifier, active_states, terminal_states)
      when is_list(parked_entries) and is_map(issues_by_identifier) do
    Enum.each(parked_entries, fn entry ->
      identifier = entry.issue_identifier

      case Map.get(issues_by_identifier, identifier) do
        %Issue{state: state} when is_binary(state) ->
          normalized = normalize_issue_state(state)

          cond do
            MapSet.member?(terminal_states, normalized) -> on_terminal(identifier)
            MapSet.member?(active_states, normalized) -> on_terminal(identifier)
            true -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  defp normalize_session_id(id) when id in [nil, "", "n/a"], do: nil
  defp normalize_session_id(id) when is_binary(id), do: id

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end
end
