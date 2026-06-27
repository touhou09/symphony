defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec squad_prompt_context() :: map()
  def squad_prompt_context do
    settings = settings!()

    %{
      "model_roles" => settings.agent.model_roles,
      "required_verifiers" => settings.agent.required_verifiers
    }
  end

  @spec ticket_content_preflight_enabled?() :: boolean()
  def ticket_content_preflight_enabled? do
    settings!().ticket.block_dispatch_on_invalid_ticket
  end

  @spec ticket_content_check_options() :: keyword()
  def ticket_content_check_options do
    ticket = settings!().ticket

    [
      required_sections: ticket.required_description_sections,
      require_acceptance_checkboxes: ticket.require_acceptance_checkboxes,
      require_validation_checkboxes: ticket.require_validation_checkboxes
    ]
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    settings
    |> semantic_checks()
    |> Enum.find(&(&1 != :ok))
    |> case do
      nil -> :ok
      error -> error
    end
  end

  defp semantic_checks(settings) do
    [
      tracker_kind_check(settings),
      tracker_required_field_check(settings, "linear", :api_key, :missing_linear_api_token),
      tracker_required_field_check(settings, "linear", :project_slug, :missing_linear_project_slug),
      tracker_required_field_check(settings, "jira", :endpoint, :missing_jira_endpoint),
      tracker_required_field_check(settings, "jira", :api_key, :missing_jira_api_token),
      tracker_required_field_check(settings, "jira", :email, :missing_jira_email),
      tracker_required_field_check(settings, "jira", :project_slug, :missing_jira_project_key)
    ]
  end

  defp tracker_kind_check(settings) do
    cond do
      is_nil(settings.tracker.kind) -> {:error, :missing_tracker_kind}
      settings.tracker.kind not in ["linear", "memory", "jira"] -> {:error, {:unsupported_tracker_kind, settings.tracker.kind}}
      true -> :ok
    end
  end

  defp tracker_required_field_check(settings, kind, field, reason) do
    if settings.tracker.kind == kind and not is_binary(Map.get(settings.tracker, field)) do
      {:error, reason}
    else
      :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
