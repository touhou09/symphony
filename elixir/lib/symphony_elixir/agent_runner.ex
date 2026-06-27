defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @default_max_no_diff_tokens 1_024
  @bounded_no_diff_label_re ~r/\bno[-_ ]?diff\b/i

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  def workspace_fingerprint_for_test(workspace), do: workspace_signature(workspace)

  @doc false
  def scoped_progress_for_test(before, after_signature), do: scoped_progress?(before, after_signature)

  @doc false
  def bounded_implementer_label?(issue), do: bounded_implementer_ticket?(issue)

  @doc false
  def max_no_diff_tokens_for_test(opts), do: bounded_no_diff_token_limit(opts)

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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    max_no_diff_tokens = bounded_no_diff_token_limit(opts)
    bounded_implementer = bounded_implementer_ticket?(issue)
    initial_fingerprint = workspace_signature(workspace)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns,
          bounded_implementer,
          initial_fingerprint,
          0,
          max_no_diff_tokens
        )
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns,
         bounded_implementer,
         prior_signature,
         no_progress_token_budget,
         max_no_diff_tokens
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    token_events_ref = make_ref()
    update_handler = turn_update_handler(codex_update_recipient, issue, self(), token_events_ref, turn_number)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: update_handler
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      turn_tokens = collect_turn_tokens(token_events_ref, issue.id, turn_number)
      next_budget = no_progress_token_budget + turn_token_total(turn_tokens, max_no_diff_tokens)
      next_signature = workspace_signature(workspace)

      if should_block_no_progress_issue?(
           bounded_implementer,
           prior_signature,
           next_signature,
           next_budget,
           max_no_diff_tokens
         ) do
        reason =
          no_progress_runtime_blocker_reason(
            issue,
            next_budget,
            max_no_diff_tokens
          )

        send_runtime_blocker(codex_update_recipient, issue, reason)
        {:error, reason}
      else
        reset_budget = if scoped_progress?(prior_signature, next_signature), do: 0, else: next_budget

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
              max_turns,
              bounded_implementer,
              next_signature,
              reset_budget,
              max_no_diff_tokens
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
  end

  defp should_block_no_progress_issue?(
         bounded_implementer,
         prior_signature,
         next_signature,
         token_budget,
         max_no_diff_tokens
       ) do
    bounded_implementer and
      !scoped_progress?(prior_signature, next_signature) and
      token_budget >= max_no_diff_tokens
  end

  defp turn_update_handler(recipient, issue, caller, token_events_ref, turn_number) do
    fn message ->
      send(caller, {token_events_ref, issue.id, turn_number, message})
      send_codex_update(recipient, issue, message)
    end
  end

  defp collect_turn_tokens(ref, issue_id, turn_number) do
    collect_turn_tokens(ref, issue_id, turn_number, %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      saw_turn_completed: false
    })
  end

  defp collect_turn_tokens(ref, issue_id, turn_number, totals) do
    receive do
      {^ref, ^issue_id, ^turn_number, update} ->
        token_usage = extract_turn_token_usage(update)

        updated_totals = add_token_usage(totals, token_usage)
        saw_completed = turn_completed_event?(update) or Map.get(updated_totals, :saw_turn_completed, false)
        collect_turn_tokens(ref, issue_id, turn_number, Map.put(updated_totals, :saw_turn_completed, saw_completed))
    after
      50 ->
        totals
    end
  end

  defp turn_token_total(%{} = totals, max_no_diff_tokens) do
    total = Map.get(totals, :total_tokens, 0)

    if total > 0 do
      total
    else
      if Map.get(totals, :saw_turn_completed, false), do: max_no_diff_tokens, else: 0
    end
  end

  defp add_token_usage(acc, usage) do
    %{
      input_tokens: Map.get(acc, :input_tokens, 0) + Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(acc, :output_tokens, 0) + Map.get(usage, :output_tokens, 0),
      total_tokens: Map.get(acc, :total_tokens, 0) + Map.get(usage, :total_tokens, 0),
      saw_turn_completed: Map.get(acc, :saw_turn_completed, false)
    }
  end

  defp extract_turn_token_usage(update) when is_map(update) do
    payloads =
      token_usage_payloads(update) ++
        [
          update[:usage],
          Map.get(update, :usage),
          Map.get(update, "usage"),
          update
        ]

    usage =
      Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
        Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
        parse_turn_completed_raw_usage(update) ||
        %{}

    %{
      input_tokens:
        read_token_field(usage, [
          "input_tokens",
          :input_tokens,
          "prompt_tokens",
          :prompt_tokens,
          "inputTokens",
          :inputTokens,
          :input
        ]),
      output_tokens:
        read_token_field(usage, [
          "output_tokens",
          :output_tokens,
          "completion_tokens",
          :completion_tokens,
          "completionTokens",
          :completionTokens,
          :output
        ]),
      total_tokens:
        read_token_field(usage, [
          "total_tokens",
          :total_tokens,
          "totalTokens",
          :totalTokens,
          "total",
          :total
        ])
    }
  end

  defp extract_turn_token_usage(_update), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp token_usage_payloads(update) when is_map(update) do
    payload = Map.get(update, :payload) || Map.get(update, "payload")
    details = Map.get(update, :details) || Map.get(update, "details")
    params = Map.get(update, :params) || Map.get(update, "params")

    nested_payload =
      if is_map(payload),
        do: Map.get(payload, :payload) || Map.get(payload, "payload"),
        else: nil

    [payload, nested_payload, details, params]
    |> Enum.filter(&is_map/1)
    |> Enum.uniq()
  end

  defp token_usage_payloads(_update), do: []

  defp parse_turn_completed_raw_usage(update) when is_map(update) do
    raw = Map.get(update, :raw) || Map.get(update, "raw")

    if is_binary(raw) do
      case Regex.run(~r/"method"\s*:\s*"turn\/completed".*?"total_tokens"\s*:\s*(\d+)/s, raw) do
        [_, total] ->
          %{total_tokens: String.to_integer(total), input_tokens: 0, output_tokens: 0}

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp parse_turn_completed_raw_usage(_update), do: %{}

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    Enum.find_value(absolute_paths, fn path ->
      map_get_token_usage(payload, path)
    end)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_get_token_usage(payload, ["params", "usage"]) ||
          map_get_token_usage(payload, [:params, :usage])

      if is_map(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp turn_completed_event?(update) when is_map(update) do
    method = Map.get(update, "method") || Map.get(update, :method)
    payload = Map.get(update, :payload) || Map.get(update, "payload")
    details = Map.get(update, :details) || Map.get(update, "details")
    nested_payload = if is_map(payload), do: Map.get(payload, :payload) || Map.get(payload, "payload"), else: nil

    method in ["turn/completed", :turn_completed] or
      (is_map(payload) and method_from_payload(payload) == "turn/completed") or
      (is_map(nested_payload) and method_from_payload(nested_payload) == "turn/completed") or
      (is_map(details) and method_from_payload(details) == "turn/completed")
  end

  defp turn_completed_event?(_update), do: false

  defp method_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method == "turn/completed" or method == :turn_completed do
      "turn/completed"
    end
  end

  defp method_from_payload(_payload), do: nil

  defp map_get_token_usage(payload, path) when is_map(payload) and is_list(path) do
    map_get_by_path(payload, path)
  end

  defp map_get_token_usage(_payload, _path), do: nil

  defp read_token_field(usage, fields) when is_map(usage) do
    Enum.find_value(fields, fn field -> integer_like(Map.get(usage, field)) end) || 0
  end

  defp read_token_field(_usage, _fields), do: 0

  defp map_get_by_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp no_progress_runtime_blocker_reason(issue, consumed_tokens, max_no_diff_tokens) do
    {:no_scoped_progress, issue.id, issue.identifier, consumed_tokens, max_no_diff_tokens}
  end

  defp bounded_no_diff_token_limit(opts) when is_list(opts) do
    configured =
      Keyword.get(opts, :max_no_diff_tokens, Keyword.get(opts, :no_diff_tokens, Keyword.get(opts, :no_diff_token_limit)))

    if is_integer(configured) and configured > 0 do
      configured
    else
      configured_no_diff_token_limit()
    end
  end

  defp bounded_no_diff_token_limit(_opts), do: configured_no_diff_token_limit()

  defp configured_no_diff_token_limit do
    configured = Config.settings!().codex.max_no_diff_tokens

    if is_integer(configured) and configured > 0 do
      configured
    else
      @default_max_no_diff_tokens
    end
  end

  defp bounded_implementer_ticket?(%Issue{labels: labels}) when is_list(labels) do
    Enum.any?(labels, fn label ->
      is_binary(label) and String.match?(String.downcase(label), @bounded_no_diff_label_re)
    end)
  end

  defp bounded_implementer_ticket?(_issue), do: false

  defp send_runtime_blocker(recipient, issue, reason) when is_pid(recipient) do
    if is_binary(issue.id) do
      send(recipient, {:agent_runtime_blocker, issue.id, reason})
    end
  end

  defp send_runtime_blocker(_recipient, _issue, _reason), do: :ok

  defp workspace_signature(workspace) when is_binary(workspace) do
    %{
      git_status: workspace_git_status(workspace),
      file_signature: workspace_file_signature(workspace)
    }
  end

  defp workspace_signature(_workspace), do: %{git_status: :unavailable, file_signature: []}

  defp workspace_git_status(workspace) when is_binary(workspace) do
    case workspace_status_cmd(workspace, ["status", "--short"]) do
      {:ok, output} -> String.trim_trailing(output)
      _ -> :unavailable
    end
  end

  defp workspace_git_status(_workspace), do: :unavailable

  defp workspace_file_signature(workspace) when is_binary(workspace) do
    case workspace_paths_for_signature(workspace) do
      {:ok, rel_paths} ->
        rel_paths
        |> Enum.map(&file_entry_signature(workspace, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {path, _size, _hash} -> path end)

      _ ->
        []
    end
  end

  defp workspace_file_signature(_workspace), do: []

  defp workspace_paths_for_signature(workspace) when is_binary(workspace) do
    with {:ok, tracked_output} <- workspace_status_cmd(workspace, ["ls-files", "-z"]),
         {:ok, untracked_output} <- workspace_status_cmd(workspace, ["ls-files", "-z", "--others", "--exclude-standard"]) do
      {
        :ok,
        (split_nul_paths(tracked_output) ++ split_nul_paths(untracked_output))
        |> Enum.uniq()
        |> Enum.reject(&ignorable_signature_path?/1)
        |> Enum.sort()
      }
    else
      _ ->
        {:ok, workspace_fallback_paths(workspace)}
    end
  end

  defp workspace_paths_for_signature(_workspace), do: {:error, :invalid_workspace}

  defp workspace_fallback_paths(workspace) when is_binary(workspace) do
    Path.wildcard(Path.join(workspace, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, workspace))
    |> Enum.reject(&ignorable_signature_path?/1)
    |> Enum.sort()
  end

  defp workspace_fallback_paths(_workspace), do: []

  defp split_nul_paths(output), do: String.split(output, <<0>>, trim: true)

  defp ignorable_signature_path?(path) when is_binary(path) do
    String.starts_with?(path, ".") or
      String.starts_with?(path, ".git/") or
      String.starts_with?(path, ".codex/")
  end

  defp ignorable_signature_path?(_path), do: true

  defp file_entry_signature(workspace, rel_path) when is_binary(rel_path) do
    path = Path.join(workspace, rel_path)

    case File.read(path) do
      {:ok, content} ->
        {rel_path, byte_size(content), Base.encode16(:crypto.hash(:sha256, content))}

      _ ->
        nil
    end
  end

  defp file_entry_signature(_workspace, _rel_path), do: nil

  defp scoped_progress?(%{git_status: before_status, file_signature: before_files}, %{
         git_status: after_status,
         file_signature: after_files
       }) do
    before_status != after_status or before_files != after_files
  end

  defp scoped_progress?(_before, _after), do: false

  defp workspace_status_cmd(workspace, args) when is_binary(workspace) and is_list(args) do
    try do
      case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        _ -> {:error, :git_failed}
      end
    rescue
      _ -> {:error, :git_failed}
    end
  end

  defp workspace_status_cmd(_workspace, _args), do: {:error, :invalid_workspace}

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

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
