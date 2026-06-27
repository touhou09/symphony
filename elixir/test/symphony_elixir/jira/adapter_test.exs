defmodule SymphonyElixir.Jira.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Adapter
  alias SymphonyElixir.Tracker

  defmodule FakeJiraClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetch_issue_states_by_ids_called, ids})
      {:ok, ids}
    end

    def get_transitions(issue_id) do
      send(self(), {:get_transitions_called, issue_id})
      Process.get({__MODULE__, :transitions})
    end

    def transition_issue(issue_id, transition_id) do
      send(self(), {:transition_issue_called, issue_id, transition_id})
      Process.get({__MODULE__, :transition_result})
    end

    def list_comments(issue_id) do
      send(self(), {:list_comments_called, issue_id})
      Process.get({__MODULE__, :comments_result})
    end

    def add_comment(issue_id, body) do
      send(self(), {:add_comment_called, issue_id, body})
      Process.get({__MODULE__, :comment_result})
    end

    def update_comment(issue_id, comment_id, body) do
      send(self(), {:update_comment_called, issue_id, comment_id, body})
      Process.get({__MODULE__, :update_comment_result})
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :jira_client_module)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :jira_client_module)
      else
        Application.put_env(:symphony_elixir, :jira_client_module, previous)
      end
    end)

    :ok
  end

  defp use_fake_client do
    Application.put_env(:symphony_elixir, :jira_client_module, FakeJiraClient)
  end

  test "tracker resolves the jira adapter for kind jira" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    assert Config.settings!().tracker.kind == "jira"
    assert Tracker.adapter() == Adapter
  end

  test "reads delegate to the configured jira client module" do
    use_fake_client()

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["10001"]} = Adapter.fetch_issue_states_by_ids(["10001"])
    assert_receive {:fetch_issue_states_by_ids_called, ["10001"]}
  end

  test "comment operations map client success and failure" do
    use_fake_client()

    Process.put({FakeJiraClient, :comments_result}, {:ok, [%{"id" => "11381"}]})
    assert {:ok, [%{"id" => "11381"}]} = Adapter.list_comments("10001")
    assert_receive {:list_comments_called, "10001"}

    Process.put({FakeJiraClient, :comment_result}, {:ok, %{"id" => "1"}})
    assert :ok = Adapter.create_comment("10001", "hello")
    assert_receive {:add_comment_called, "10001", "hello"}

    Process.put({FakeJiraClient, :comment_result}, {:error, {:jira_api_status, 400}})
    assert {:error, {:jira_api_status, 400}} = Adapter.create_comment("10001", "bad")

    Process.put({FakeJiraClient, :update_comment_result}, {:ok, %{"id" => "11381"}})
    assert :ok = Adapter.update_comment("10001", "11381", "updated")
    assert_receive {:update_comment_called, "10001", "11381", "updated"}

    Process.put({FakeJiraClient, :update_comment_result}, {:error, {:jira_api_status, 404}})
    assert {:error, {:jira_api_status, 404}} = Adapter.update_comment("10001", "missing", "updated")
  end

  test "update_issue_state resolves a transition by target status name" do
    use_fake_client()

    Process.put(
      {FakeJiraClient, :transitions},
      {:ok, %{"transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}, %{"id" => "21", "to" => %{}}]}}
    )

    Process.put({FakeJiraClient, :transition_result}, {:ok, %{}})

    assert :ok = Adapter.update_issue_state("10001", " done ")
    assert_receive {:get_transitions_called, "10001"}
    assert_receive {:transition_issue_called, "10001", "31"}
  end

  test "update_issue_state prefers success terminal transitions for generic done targets" do
    use_fake_client()

    Process.put(
      {FakeJiraClient, :transitions},
      {:ok,
       %{
         "transitions" => [
           %{"id" => "41", "to" => %{"name" => "취소"}},
           %{"id" => "51", "to" => %{"name" => "해결됨"}}
         ]
       }}
    )

    Process.put({FakeJiraClient, :transition_result}, {:ok, %{}})

    assert :ok = Adapter.update_issue_state("10001", "Done")
    assert_receive {:transition_issue_called, "10001", "51"}
  end

  test "update_issue_state returns state_not_found when no transition matches" do
    use_fake_client()

    # First transition has no target name (exercises the nil-name path), second doesn't match.
    Process.put(
      {FakeJiraClient, :transitions},
      {:ok, %{"transitions" => [%{"id" => "21", "to" => %{}}, %{"id" => "31", "to" => %{"name" => "Done"}}]}}
    )

    assert {:error, :state_not_found} = Adapter.update_issue_state("10001", "Merging")
  end

  test "update_issue_state returns state_not_found when matching transition lacks an id" do
    use_fake_client()
    Process.put({FakeJiraClient, :transitions}, {:ok, %{"transitions" => [%{"to" => %{"name" => "Done"}}]}})

    assert {:error, :state_not_found} = Adapter.update_issue_state("10001", "Done")
  end

  test "update_issue_state returns state_not_found for a payload without a transitions list" do
    use_fake_client()
    Process.put({FakeJiraClient, :transitions}, {:ok, %{}})

    assert {:error, :state_not_found} = Adapter.update_issue_state("10001", "Done")
  end

  test "update_issue_state propagates a get_transitions error" do
    use_fake_client()
    Process.put({FakeJiraClient, :transitions}, {:error, :boom})

    assert {:error, :boom} = Adapter.update_issue_state("10001", "Done")
  end

  test "update_issue_state propagates a transition_issue error" do
    use_fake_client()
    Process.put({FakeJiraClient, :transitions}, {:ok, %{"transitions" => [%{"id" => "31", "to" => %{"name" => "Done"}}]}})
    Process.put({FakeJiraClient, :transition_result}, {:error, {:jira_api_status, 409}})

    assert {:error, {:jira_api_status, 409}} = Adapter.update_issue_state("10001", "Done")
  end
end
