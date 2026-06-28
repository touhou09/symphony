defmodule SymphonyElixir.Codex.AuthPreflight do
  @moduledoc false

  @default_auth_path Path.join([System.user_home!(), ".codex", "auth.json"])

  @type check_result :: :ok | {:error, String.t()}

  @spec default_auth_path() :: Path.t()
  def default_auth_path, do: @default_auth_path

  @spec check(map() | keyword()) :: check_result()
  def check(%{auth_preflight_enabled: false}), do: :ok

  def check(%{auth_preflight_enabled: true} = codex) do
    codex
    |> opts_from_codex()
    |> check()
  end

  def check(opts) when is_list(opts) do
    if Keyword.get(opts, :enabled, false) do
      path = Keyword.get(opts, :path) || @default_auth_path
      max_age_ms = Keyword.get(opts, :max_age_ms, 0)

      with :ok <- regular_auth_file(path),
           {:ok, auth} <- read_auth_json(path),
           :ok <- recognizable_credentials(auth),
           :ok <- fresh_enough(auth, max_age_ms) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp opts_from_codex(codex) do
    [
      enabled: Map.get(codex, :auth_preflight_enabled, false),
      path: Map.get(codex, :auth_json_path) || @default_auth_path,
      max_age_ms: Map.get(codex, :auth_max_age_ms, 0)
    ]
  end

  defp regular_auth_file(path) when is_binary(path) do
    if File.regular?(path) do
      :ok
    else
      {:error, "codex authentication preflight failed: auth file missing at #{path}"}
    end
  end

  defp regular_auth_file(path), do: {:error, "codex authentication preflight failed: invalid auth path #{inspect(path)}"}

  defp read_auth_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, auth} <- Jason.decode(contents),
         true <- is_map(auth) do
      {:ok, auth}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "codex authentication preflight failed: auth file is not valid JSON: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "codex authentication preflight failed: unable to read auth file: #{inspect(reason)}"}

      false ->
        {:error, "codex authentication preflight failed: auth file must contain a JSON object"}
    end
  end

  defp recognizable_credentials(auth) when is_map(auth) do
    cond do
      chatgpt_tokens?(auth) ->
        :ok

      api_key?(auth) ->
        :ok

      true ->
        {:error, "codex authentication preflight failed: auth file does not contain recognizable Codex credentials"}
    end
  end

  defp chatgpt_tokens?(auth) do
    auth
    |> Map.get("tokens")
    |> case do
      %{} = tokens -> non_blank?(Map.get(tokens, "access_token")) and non_blank?(Map.get(tokens, "refresh_token"))
      _ -> false
    end
  end

  defp api_key?(auth) do
    case Map.get(auth, "OPENAI_API_KEY") do
      value when is_binary(value) -> non_blank?(value)
      %{} = value -> map_size(value) > 0
      _ -> false
    end
  end

  defp fresh_enough(_auth, max_age_ms) when not is_integer(max_age_ms) or max_age_ms <= 0, do: :ok

  defp fresh_enough(auth, max_age_ms) do
    if chatgpt_tokens?(auth) do
      check_last_refresh(auth, max_age_ms)
    else
      :ok
    end
  end

  defp check_last_refresh(auth, max_age_ms) do
    case Map.get(auth, "last_refresh") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, timestamp, _offset} ->
            age_ms = DateTime.diff(DateTime.utc_now(), timestamp, :millisecond)

            if age_ms > max_age_ms do
              {:error, "codex authentication preflight failed: auth refresh is stale; last_refresh=#{value} age_ms=#{age_ms} max_age_ms=#{max_age_ms}"}
            else
              :ok
            end

          {:error, _reason} ->
            {:error, "codex authentication preflight failed: auth last_refresh is not a valid timestamp"}
        end

      _ ->
        {:error, "codex authentication preflight failed: auth last_refresh is missing"}
    end
  end

  defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank?(_value), do: false
end
