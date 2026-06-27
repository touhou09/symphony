defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Squad.EvidenceCheck
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @squad_evidence_path "docs/codex-squad-evidence.md"

  @doc false
  @spec squad_codex_command_for_test(String.t(), String.t()) :: String.t()
  def squad_codex_command_for_test(command, model) when is_binary(command) and is_binary(model) do
    codex_command_for_model(command, model)
  end

  @doc false
  @spec squad_role_prompt_for_test(Issue.t(), String.t(), String.t(), pos_integer(), pos_integer()) :: String.t()
  def squad_role_prompt_for_test(%Issue{} = issue, role, model, role_number, total_roles)
      when is_binary(role) and is_binary(model) and is_integer(role_number) and is_integer(total_roles) do
    build_squad_role_prompt(issue, [], role, model, role_number, total_roles)
  end

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
    if Config.settings!().agent.squad_enabled do
      run_squad_turns(workspace, issue, codex_update_recipient, opts, worker_host)
    else
      run_single_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp run_single_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_squad_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    settings = Config.settings!()
    roles = squad_roles(settings)
    total_roles = length(roles)

    roles
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {{role, model}, role_number}, :ok ->
      prompt = build_squad_role_prompt(issue, opts, role, model, role_number, total_roles)
      command = codex_command_for_model(settings.codex.command, model)

      case AppServer.start_session(workspace, worker_host: worker_host, codex_command: command) do
        {:ok, session} ->
          try do
            case AppServer.run_turn(
                   session,
                   prompt,
                   issue,
                   on_message: codex_message_handler(codex_update_recipient, issue)
                 ) do
              {:ok, turn_session} ->
                Logger.info(
                  "Completed squad role for #{issue_context(issue)} role=#{role} model=#{model} session_id=#{turn_session[:session_id]} workspace=#{workspace} role_turn=#{role_number}/#{total_roles}"
                )

                {:cont, :ok}

              {:error, reason} ->
                {:halt, {:error, {:squad_role_failed, role, reason}}}
            end
          after
            AppServer.stop_session(session)
          end

        {:error, reason} ->
          {:halt, {:error, {:squad_role_start_failed, role, reason}}}
      end
    end)
    |> case do
      :ok -> validate_squad_evidence(workspace)
      {:error, _reason} = error -> error
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

  defp build_squad_role_prompt(issue, opts, role, model, role_number, total_roles) do
    base_prompt = PromptBuilder.build_prompt(issue, opts)

    """
    #{base_prompt}

    ## Symphony squad role turn

    Role: #{role}
    Model: #{model}
    Role turn: #{role_number}/#{total_roles}
    Evidence file: #{@squad_evidence_path}

    Run this role as a separate Codex squad context. Keep all durable handoff evidence in `#{@squad_evidence_path}`.

    Role contract:
    - Before any tracker comment/write tool call, create or update a workspace file so `git status --short` is non-empty. The preferred first edit is `#{@squad_evidence_path}`.
    - `cto`: first create or refresh `#{@squad_evidence_path}` with `## Scope` and `## CTO Plan`; define bounded implementation and validation criteria.
    - `implementer`: first create a failing/regression test or the smallest code/docs edit in the workspace, then implement the scoped changes and write `## Implementation` with role/model/result. The first edit path must be explicit and verifiable in evidence.
    - verifier roles: first append a verification note to `#{@squad_evidence_path}`, inspect the diff and evidence, run targeted validation, then add a `## Verification` checklist row exactly containing the verifier role, configured model, and `PASS` or `FAIL`.

    No-diff contract:
    - Tracker workpad-only progress is not implementation progress. If no safe first file edit exists, write a `### Runtime Blocker` comment with the concrete blocker and stop before extended analysis.
    - Run `git status --short` before tracker workpad updates. A normal workpad update is allowed only after the workspace has a code, test, docs, or evidence diff.

    Completion contract:
    - Do not mark the issue successful unless `mix squad.check --file #{@squad_evidence_path} --workflow WORKFLOW.md` passes.
    - If this role cannot complete, update the tracker workpad with the concrete blocker and stop instead of guessing.
    """
  end

  defp squad_roles(settings) do
    model_roles = settings.agent.model_roles

    ["cto", "implementer" | settings.agent.required_verifiers]
    |> Enum.uniq()
    |> Enum.map(fn role -> {role, Map.fetch!(model_roles, role)} end)
  end

  defp validate_squad_evidence(workspace) do
    evidence_path = Path.join(workspace, @squad_evidence_path)

    case EvidenceCheck.validate_file(evidence_path, Config.squad_prompt_context()) do
      :ok -> :ok
      {:error, errors} -> {:error, {:squad_evidence_failed, errors}}
    end
  end

  defp codex_command_for_model(command, model) when is_binary(command) and is_binary(model) do
    config_arg = "--config " <> shell_quote("model=#{inspect(model)}")
    trimmed = String.trim(command)

    if Regex.match?(~r/\bapp-server\s*$/, trimmed) do
      Regex.replace(~r/\s+app-server\s*$/, trimmed, " #{config_arg} app-server")
    else
      trimmed <> " " <> config_arg
    end
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
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
