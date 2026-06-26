defmodule SymphonyElixir.Jira.Adapter do
  @moduledoc """
  Jira-backed tracker adapter.

  Reads delegate to a swappable client module (overridable in tests via
  `:jira_client_module`). Writes resolve a Jira workflow transition by target
  status name, then apply it; comments post ADF bodies. Emits the shared
  `SymphonyElixir.Linear.Issue` struct, like every tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Jira.Client

  @impl true
  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @impl true
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @impl true
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @impl true
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().add_comment(issue_id, body) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, transitions} <- client_module().get_transitions(issue_id),
         {:ok, transition_id} <- resolve_transition_id(transitions, state_name),
         {:ok, _response} <- client_module().transition_issue(issue_id, transition_id) do
      :ok
    else
      :not_found -> {:error, :state_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :jira_client_module, Client)
  end

  defp resolve_transition_id(%{"transitions" => transitions}, state_name) when is_list(transitions) do
    target = normalize(state_name)

    transitions
    |> Enum.find(fn transition ->
      normalize(get_in(transition, ["to", "name"])) == target
    end)
    |> case do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _ -> :not_found
    end
  end

  defp resolve_transition_id(_transitions, _state_name), do: :not_found

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
