defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Squad.EvidenceCheck

  @type worker_host :: String.t() | nil

  @squad_evidence_path "docs/codex-squad-evidence.md"
  @squad_evidence_check_command "cd elixir && mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md"

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

      {:error, {:runtime_blocker, _} = reason} ->
        Logger.error("Agent run blocked for #{issue_context(issue)}: #{inspect(reason)}")
        exit(reason)

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
    |> Enum.reduce_while(:ok, fn role_entry, :ok ->
      run_squad_role(role_entry, settings, workspace, issue, codex_update_recipient, opts, {worker_host, total_roles})
    end)
    |> case do
      :ok -> validate_squad_evidence(workspace)
      {:error, _reason} = error -> error
    end
  end

  defp run_squad_role({{role, model}, role_number}, settings, workspace, issue, recipient, opts, {worker_host, total_roles}) do
    prompt = build_squad_role_prompt(issue, opts, role, model, role_number, total_roles)
    command = codex_command_for_model(settings.codex.command, model)
    pre_state = role_pre_change_state(role, workspace)
    role_context = {role, model, role_number, total_roles, prompt}

    case AppServer.start_session(workspace, worker_host: worker_host, codex_command: command) do
      {:ok, session} ->
        run_started_squad_role(session, role_context, pre_state, workspace, issue, recipient)

      {:error, reason} ->
        {:halt, {:error, {:squad_role_start_failed, role, reason}}}
    end
  end

  defp run_started_squad_role(session, role_context, pre_state, workspace, issue, recipient) do
    {_role, _model, _role_number, _total_roles, prompt} = role_context

    try do
      session
      |> AppServer.run_turn(prompt, issue, on_message: codex_message_handler(recipient, issue))
      |> handle_squad_role_result(role_context, pre_state, workspace, issue)
    after
      AppServer.stop_session(session)
    end
  end

  defp handle_squad_role_result({:ok, turn_session}, role_context, pre_state, workspace, issue) do
    {role, model, role_number, total_roles, _prompt} = role_context

    case verify_role_progress(role, pre_state, workspace) do
      :ok ->
        log_squad_role_complete(issue, role, model, turn_session, workspace, role_number, total_roles)
        {:cont, :ok}

      {:error, reason} ->
        Logger.warning("Implementer role blocked early for #{issue_context(issue)}: #{reason}")
        {:halt, {:error, {:runtime_blocker, reason}}}
    end
  end

  defp handle_squad_role_result({:error, reason}, role_context, _pre_state, _workspace, _issue) do
    {role, _model, _role_number, _total_roles, _prompt} = role_context

    {:halt, {:error, {:squad_role_failed, role, reason}}}
  end

  defp role_pre_change_state("implementer", workspace), do: workspace_change_state(workspace)
  defp role_pre_change_state(_role, _workspace), do: :skip

  defp verify_role_progress("implementer", pre_state, workspace) do
    verify_implementer_turn_progress(pre_state, workspace)
  end

  defp verify_role_progress(_role, _pre_state, _workspace), do: :ok

  defp log_squad_role_complete(issue, role, model, turn_session, workspace, role_number, total_roles) do
    Logger.info(
      "Completed squad role for #{issue_context(issue)} role=#{role} model=#{model} " <>
        "session_id=#{turn_session[:session_id]} workspace=#{workspace} role_turn=#{role_number}/#{total_roles}"
    )
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
    - `implementer`: first create a failing/regression test or the smallest code/docs edit in the workspace (excluding `#{@squad_evidence_path}`), then implement the scoped changes and write `## Implementation` with role/model/result. The first edit path must be explicit and verifiable in evidence.
    - verifier roles: first append a verification note to `#{@squad_evidence_path}`, inspect the diff and evidence, run targeted validation, then add a `## Verification` checklist row exactly containing the verifier role, configured model, and `PASS` or `FAIL`.

    No-diff contract:
    - Tracker workpad-only progress is not implementation progress. If no safe first file edit exists, write a `### Runtime Blocker` comment with the concrete blocker and stop before extended analysis.
    - Run `git status --short` before tracker workpad updates. A normal workpad update is allowed only after the workspace has a code, test, docs, or evidence diff.

    Completion contract:
    - Do not mark the issue successful unless `#{@squad_evidence_check_command}` passes.
    - If this role cannot complete, update the tracker workpad with the concrete blocker and stop instead of guessing.
    """
  end

  defp verify_implementer_turn_progress(:skip, _workspace), do: :ok

  defp verify_implementer_turn_progress(:unknown, _workspace),
    do: {:error, "workspace status could not be verified for implementer change checks"}

  defp verify_implementer_turn_progress(:error, _workspace),
    do: {:error, "workspace status could not be verified for implementer change checks"}

  defp verify_implementer_turn_progress(pre_state, workspace) when is_map(pre_state) and is_binary(workspace) do
    post_state = workspace_change_state(workspace)

    case post_state do
      :unknown ->
        {:error, "workspace status could not be verified for implementer change checks"}

      post_state when is_map(post_state) ->
        if implements_scoped_workspace_progress?(pre_state, post_state) do
          :ok
        else
          {:error, "implementer must make a workspace edit outside #{@squad_evidence_path} before tracker progress updates"}
        end
    end
  end

  defp implements_scoped_workspace_progress?(pre_state, post_state)
       when is_map(pre_state) and is_map(post_state) do
    Enum.any?(post_state, fn {path, post_signature} ->
      path != @squad_evidence_path and Map.get(pre_state, path) != post_signature
    end) or
      Enum.any?(pre_state, fn {path, pre_signature} ->
        path != @squad_evidence_path and Map.get(post_state, path) != pre_signature
      end)
  end

  defp implements_scoped_workspace_progress?(_pre_state, _post_state), do: false

  defp workspace_change_state(workspace) when is_binary(workspace) and workspace != "" do
    case workspace_status_map(workspace) do
      :unknown -> :unknown
      entries -> entries
    end
  end

  defp workspace_change_state(_workspace), do: :unknown

  defp workspace_status_map(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain=v1", "--branch", "-uall"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_workspace_change_map(path, output)

      {_output, _status} ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp parse_workspace_change_map(workspace, output) when is_binary(workspace) and is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "## "))
    |> Enum.map(&trim_workspace_status_path/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn path, acc ->
      Map.put(acc, path, workspace_entry_signature(Path.join(workspace, path)))
    end)
  end

  defp trim_workspace_status_path(line) when is_binary(line) do
    if String.starts_with?(line, "?? ") or String.starts_with?(line, "R") do
      case String.split(line, " -> ") do
        [_from, to] -> String.trim(to)
        _ -> String.slice(line, 3..-1//1) |> String.trim()
      end
    else
      String.slice(line, 3..-1//1)
      |> String.trim()
    end
  end

  defp trim_workspace_status_path(_line), do: ""

  defp workspace_entry_signature(path) when is_binary(path) do
    if File.exists?(path) do
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular}} -> file_content_signature(path)
        {:ok, %File.Stat{type: type, size: size}} -> {type, size}
        {:error, _reason} -> :unknown
      end
    else
      :missing
    end
  end

  defp workspace_entry_signature(_path), do: :unknown

  defp file_content_signature(path) do
    case File.read(path) do
      {:ok, contents} -> {:sha256, :crypto.hash(:sha256, contents)}
      {:error, _reason} -> :unknown
    end
  end

  @doc false
  @spec workspace_change_state_for_test(Path.t()) :: map() | :unknown
  def workspace_change_state_for_test(path), do: workspace_change_state(path)

  @doc false
  @spec implements_scoped_workspace_progress_for_test(map() | term(), map() | term()) :: boolean()
  def implements_scoped_workspace_progress_for_test(pre_state, post_state),
    do: implements_scoped_workspace_progress?(pre_state, post_state)

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
