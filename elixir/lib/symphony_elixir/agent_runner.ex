defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.SquadRun
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    model_roles = Config.settings!().agent.model_roles || %{}

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        if squad_roles_configured?(model_roles) do
          run_squad_codex_turns(session, issue, codex_update_recipient, model_roles)
        else
          do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp squad_roles_configured?(model_roles) when is_map(model_roles) do
    Enum.all?(SquadRun.roles(), fn role ->
      Map.has_key?(model_roles, to_string(role))
    end)
  end

  defp squad_roles_configured?(_model_roles), do: false

  defp run_squad_codex_turns(app_session, issue, codex_update_recipient, model_roles) do
    run = SquadRun.new(issue)
    evidence_path = Path.expand("docs/codex-squad-evidence.md")

    with {:ok, run} <- run_squad_role(:cto, app_session, issue, codex_update_recipient, run, model_roles),
         {:ok, run} <- run_squad_role(:implementer, app_session, issue, codex_update_recipient, run, model_roles),
         {:ok, run} <- run_squad_role(:verifier, app_session, issue, codex_update_recipient, run, model_roles),
         {:ok, run} <- run_squad_role(:final_verifier, app_session, issue, codex_update_recipient, run, model_roles) do
      SquadRun.write_markdown(run, evidence_path)

      if SquadRun.handoff_allowed?(run) do
        Logger.info("Squad handoff gate passed for #{issue_context(issue)}")
        :ok
      else
        Logger.warning("Squad handoff gate failed for #{issue_context(issue)}: verifier or final_verifier did not PASS")
        {:error, :squad_handoff_blocked}
      end
    else
      {:error, reason, run} ->
        _ = SquadRun.write_markdown(run, evidence_path)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_squad_role(
         role,
         app_session,
         issue,
         codex_update_recipient,
         %SquadRun{} = run,
         model_roles
       ) do
    role_model = Map.get(model_roles, to_string(role))
    prompt = build_squad_prompt(role, issue, run)

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue),
           model: role_model
         ) do
      {:ok, completion} ->
        {:ok, SquadRun.put_completion(run, role, role_model, raw_turn_completion(completion))}

      {:error, reason} ->
        {:error, {:squad_turn_error, role, reason}, run |> SquadRun.put_limitation("#{role} turn failed: #{inspect(reason)}")}
    end
  end

  defp raw_turn_completion(%{completion: completion}) when is_map(completion), do: completion
  defp raw_turn_completion(%{result: completion}) when is_map(completion), do: completion
  defp raw_turn_completion(completion), do: completion

  defp build_squad_prompt(:cto, issue, _run) do
    [
      "You are the CTO role for this ticket.",
      "Produce a concise execution plan and decomposition.",
      "",
      PromptBuilder.build_prompt(issue)
    ]
    |> Enum.join("\n")
  end

  defp build_squad_prompt(:implementer, issue, run) do
    cto_summary = run.role_artifacts[:cto].payload_summary || "pending"

    [
      "You are the implementer role.",
      "Use the CTO plan to implement the ticket safely.",
      "CTO summary: #{cto_summary}",
      "",
      PromptBuilder.build_prompt(issue)
    ]
    |> Enum.join("\n")
  end

  defp build_squad_prompt(:verifier, issue, run) do
    impl_summary = run.role_artifacts[:implementer].payload_summary || "pending"

    [
      "You are the verifier role.",
      "Verify implementation against the ticket and prior context.",
      "Implementer summary: #{impl_summary}",
      "Respond with a strict PASS or FAIL verdict.",
      "",
      PromptBuilder.build_prompt(issue)
    ]
    |> Enum.join("\n")
  end

  defp build_squad_prompt(:final_verifier, issue, run) do
    verifier_summary = run.role_artifacts[:verifier].payload_summary || "pending"

    [
      "You are the final_verifier role.",
      "Review verifier output and final implementation status.",
      "Verifier summary: #{verifier_summary}",
      "Respond with PASS or FAIL.",
      "",
      PromptBuilder.build_prompt(issue)
    ]
    |> Enum.join("\n")
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
