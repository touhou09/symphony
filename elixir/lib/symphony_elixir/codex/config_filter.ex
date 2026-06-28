defmodule SymphonyElixir.Codex.ConfigFilter do
  @moduledoc false

  @safe_config_subpath [".codex", "config.toml"]
  @safe_auth_subpath [".codex", "auth.json"]
  @host_config_path "/run/symphony/codex-host/config.toml"
  @host_auth_path "/root/.codex/auth.json"
  @workspace_runtime_excludes [".codex/", ".hex/", ".mix/"]

  @spec inject_sandbox_config(String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def inject_sandbox_config(codex_command, workspace, opts \\ [])
      when is_binary(codex_command) and is_binary(workspace) do
    source_config_path = Keyword.get(opts, :source_config_path, @host_config_path)
    source_auth_path = Keyword.get(opts, :source_auth_path, @host_auth_path)

    case ensure_workspace_runtime_excludes(workspace) do
      :ok -> inject_host_config(codex_command, workspace, source_config_path, source_auth_path)
      {:error, reason} -> {:error, {:safe_config_generation_failed, reason}}
    end
  end

  defp inject_host_config(codex_command, workspace, source_config_path, source_auth_path) do
    if File.regular?(source_config_path) do
      write_safe_host_config(codex_command, workspace, source_config_path, source_auth_path)
    else
      {:ok, codex_command}
    end
  end

  defp write_safe_host_config(codex_command, workspace, source_config_path, source_auth_path) do
    with {:ok, safe_config_path} <- safe_config_path(workspace),
         :ok <- write_sanitized_config(source_config_path, safe_config_path),
         :ok <- link_host_auth(source_auth_path, safe_auth_path(workspace)),
         true <- String.trim(safe_config_path) != "" do
      {:ok, append_config_arg(codex_command, workspace)}
    else
      {:error, reason} -> {:error, {:safe_config_generation_failed, reason}}
      false -> {:error, {:invalid_safe_config_path, workspace}}
    end
  end

  defp ensure_workspace_runtime_excludes(workspace) when is_binary(workspace) do
    case git_exclude_path(workspace) do
      {:ok, exclude_path} ->
        with :ok <- File.mkdir_p(Path.dirname(exclude_path)),
             {:ok, contents} <- read_optional_file(exclude_path),
             next_contents <- append_missing_excludes(contents, @workspace_runtime_excludes),
             :ok <- File.write(exclude_path, next_contents) do
          :ok
        else
          {:error, reason} -> {:error, {:git_exclude_update_failed, reason}}
        end

      :not_git ->
        :ok

      {:error, reason} ->
        {:error, {:git_exclude_path_failed, reason}}
    end
  end

  defp git_exclude_path(workspace) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--git-path", "info/exclude"], stderr_to_stdout: true) do
      {path, 0} ->
        path =
          path
          |> String.trim()
          |> Path.expand(workspace)

        {:ok, path}

      {_output, _status} ->
        :not_git
    end
  rescue
    error -> {:error, error}
  end

  defp read_optional_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_missing_excludes(contents, patterns) when is_binary(contents) and is_list(patterns) do
    existing =
      contents
      |> String.split("\n", trim: true)
      |> MapSet.new(&String.trim/1)

    missing = Enum.reject(patterns, &MapSet.member?(existing, &1))

    cond do
      missing == [] ->
        contents

      contents == "" ->
        Enum.join(missing, "\n") <> "\n"

      String.ends_with?(contents, "\n") ->
        contents <> Enum.join(missing, "\n") <> "\n"

      true ->
        contents <> "\n" <> Enum.join(missing, "\n") <> "\n"
    end
  end

  @spec sanitize_config_contents(String.t()) :: String.t()
  def sanitize_config_contents(config_contents) when is_binary(config_contents) do
    config_lines = String.split(config_contents, "\n", trim: false)

    {_skipping, sanitized_lines} =
      Enum.reduce(config_lines, {false, []}, fn line, {skip_state_section, lines} ->
        maybe_next_state(line, skip_state_section, lines)
      end)

    sanitized_lines
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @spec write_sanitized_config(Path.t(), Path.t()) :: :ok | {:error, term()}
  def write_sanitized_config(source_config_path, safe_config_path) when is_binary(source_config_path) do
    with {:ok, source_contents} <- File.read(source_config_path),
         :ok <- File.mkdir_p(Path.dirname(safe_config_path)),
         :ok <- File.write(safe_config_path, sanitize_config_contents(source_contents)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_config_path(workspace) when is_binary(workspace) do
    safe_config_path = Path.join([workspace | @safe_config_subpath])
    {:ok, safe_config_path}
  end

  defp safe_auth_path(workspace) when is_binary(workspace) do
    Path.join([workspace | @safe_auth_subpath])
  end

  defp link_host_auth(source_auth_path, safe_auth_path) when is_binary(source_auth_path) and is_binary(safe_auth_path) do
    if File.regular?(source_auth_path) do
      with :ok <- File.mkdir_p(Path.dirname(safe_auth_path)),
           :ok <- remove_existing_auth_link(safe_auth_path),
           :ok <- File.ln_s(source_auth_path, safe_auth_path) do
        :ok
      else
        {:error, reason} -> {:error, {:auth_link_failed, reason}}
      end
    else
      :ok
    end
  end

  defp remove_existing_auth_link(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_config_arg(codex_command, home_path)
       when is_binary(codex_command) and is_binary(home_path) do
    if String.starts_with?(String.trim(codex_command), "HOME=") do
      codex_command
    else
      "HOME=#{shell_quote(home_path)} #{codex_command}"
    end
  end

  defp maybe_next_state(line, true, lines) do
    if section_header?(line) do
      if denied_section?(line) do
        {true, lines}
      else
        {false, [line | lines]}
      end
    else
      {true, lines}
    end
  end

  defp maybe_next_state(line, false, lines) do
    cond do
      denied_inline_state?(line) ->
        {false, lines}

      section_header?(line) ->
        if denied_section?(line) do
          {true, lines}
        else
          {false, [line | lines]}
        end

      true ->
        {false, [line | lines]}
    end
  end

  defp section_header?(line) when is_binary(line) do
    String.match?(line, ~r/^\s*\[[^\]]+\]\s*$/)
  end

  defp denied_section?(line) when is_binary(line) do
    normalized = String.trim(line)

    normalized in ["[hooks.state]", "[[hooks.state]]"] or
      String.starts_with?(normalized, "[hooks.state ") or
      String.starts_with?(normalized, "[[hooks.state ")
  end

  defp denied_inline_state?(line) when is_binary(line) do
    Regex.match?(~r/^\s*hooks\.state\s*=/, line)
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
