defmodule SymphonyElixir.ParkedRunsHooks do
  @moduledoc """
  Orchestrator hooks that park runs on leave-active and clear them on terminal.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ParkedRuns

  @keep_parked_states MapSet.new(["human review", "merging"])

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
  True for Linear states that remain parked even when treated as active (Merging)
  or when absent from the poll fetch (Human Review).
  """
  @spec keep_parked_state?(String.t() | nil) :: boolean()
  def keep_parked_state?(state) when is_binary(state) do
    MapSet.member?(@keep_parked_states, normalize_issue_state(state))
  end

  def keep_parked_state?(_state), do: false

  @doc """
  Drop parked entries that are terminal or back in active work (e.g. Rework).
  Keep Human Review / Merging / unknown (not present in `issues_by_identifier`).
  """
  @spec reconcile([map()], %{optional(String.t()) => Issue.t()}, MapSet.t(), MapSet.t()) :: :ok
  def reconcile(parked_entries, issues_by_identifier, active_states, terminal_states)
      when is_list(parked_entries) and is_map(issues_by_identifier) do
    Enum.each(parked_entries, fn entry ->
      reconcile_entry(entry.issue_identifier, issues_by_identifier, active_states, terminal_states)
    end)
  end

  defp reconcile_entry(identifier, issues_by_identifier, active_states, terminal_states)
       when is_binary(identifier) do
    case Map.get(issues_by_identifier, identifier) do
      %Issue{state: state} when is_binary(state) ->
        maybe_clear_parked(identifier, state, active_states, terminal_states)

      _ ->
        :ok
    end
  end

  defp maybe_clear_parked(identifier, state, active_states, terminal_states) do
    normalized = normalize_issue_state(state)

    cond do
      keep_parked_state?(state) ->
        :ok

      MapSet.member?(terminal_states, normalized) ->
        on_terminal(identifier)

      MapSet.member?(active_states, normalized) ->
        on_terminal(identifier)

      true ->
        :ok
    end
  end

  defp normalize_session_id(id) when id in [nil, "", "n/a"], do: nil
  defp normalize_session_id(id) when is_binary(id), do: id

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end
end
