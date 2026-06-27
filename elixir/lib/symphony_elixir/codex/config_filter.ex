defmodule SymphonyElixir.Codex.ConfigFilter do
  @moduledoc false

  @safe_config_subpath [".codex", "config.toml"]
  @host_config_path "/run/symphony/codex-host/config.toml"

  @spec inject_sandbox_config(String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def inject_sandbox_config(codex_command, workspace, opts \\ [])
      when is_binary(codex_command) and is_binary(workspace) do
    source_config_path = Keyword.get(opts, :source_config_path, @host_config_path)

    if File.regular?(source_config_path) do
      with {:ok, safe_config_path} <- safe_config_path(workspace),
           :ok <- write_sanitized_config(source_config_path, safe_config_path),
           true <- String.trim(safe_config_path) != "" do
        {:ok, append_config_arg(codex_command, safe_config_path)}
      else
        {:error, reason} -> {:error, {:safe_config_generation_failed, reason}}
        false -> {:error, {:invalid_safe_config_path, workspace}}
      end
    else
      {:ok, codex_command}
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

  defp append_config_arg(codex_command, safe_config_path)
       when is_binary(codex_command) and is_binary(safe_config_path) do
    if String.starts_with?(String.trim(codex_command), "HOME=") do
      codex_command
    else
      "HOME=#{shell_quote(Path.dirname(safe_config_path))} #{codex_command}"
    end
  end

  defp maybe_next_state(line, true, lines) do
    cond do
      section_header?(line) ->
        if denied_section?(line) do
          {true, lines}
        else
          {false, [line | lines]}
        end

      true ->
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
