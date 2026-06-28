defmodule SymphonyElixir.Codex.AuthKeeper do
  @moduledoc false

  @type auth_status :: :ok | :missing | :malformed | :stale | :unauthorized | :unknown

  @host_auth_path "/root/.codex/auth.json"
  @default_stale_threshold_ms 24 * 60 * 60 * 1000

  @spec auth_path :: String.t()
  def auth_path do
    Application.get_env(:symphony_elixir, :codex_auth_path, @host_auth_path)
  end

  @spec stale_threshold_ms :: pos_integer()
  def stale_threshold_ms do
    Application.get_env(:symphony_elixir, :codex_auth_stale_threshold_ms, @default_stale_threshold_ms)
  end

  @spec status :: auth_status()
  def status do
    status(auth_path(), stale_threshold_ms: stale_threshold_ms())
  end

  @spec status_metadata(String.t(), keyword()) :: {auth_status(), integer() | nil}
  def status_metadata(path, opts \\ []) when is_binary(path) do
    {status(path, opts), auth_file_modified_at_ms(path)}
  end

  @spec auth_file_modified_at_ms(String.t()) :: integer() | nil
  def auth_file_modified_at_ms(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime_seconds}} -> mtime_seconds * 1_000
      _ -> nil
    end
  end

  @spec status(String.t(), keyword()) :: auth_status()
  def status(path, opts \\ []) when is_binary(path) do
    stale_threshold_ms =
      case Keyword.fetch(opts, :stale_threshold_ms) do
        {:ok, threshold} when is_integer(threshold) and threshold > 0 -> threshold
        _ -> stale_threshold_ms()
      end

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime_seconds}} ->
        with {:ok, contents} <- File.read(path),
             {:ok, _auth_map} <- decode(contents),
             :ok <- validate_freshness(mtime_seconds * 1_000, stale_threshold_ms) do
          :ok
        else
          {:error, reason} -> reason_to_status(reason)
          :stale -> :stale
        end

      {:ok, %File.Stat{}} ->
        :unknown

      {:error, :enoent} ->
        :missing

      {:error, _reason} ->
        :unknown
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, auth_data} when is_map(auth_data) -> {:ok, auth_data}
      {:ok, _other} -> {:error, :malformed}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp validate_freshness(modified_at_ms, stale_threshold_ms) when is_integer(modified_at_ms) do
    now_ms = System.system_time(:millisecond)

    if now_ms - modified_at_ms >= stale_threshold_ms do
      :stale
    else
      :ok
    end
  end

  defp reason_to_status(:malformed), do: :malformed
  defp reason_to_status(_), do: :unknown

  @spec status_reason(auth_status()) :: String.t()
  def status_reason(:ok), do: "ok"
  def status_reason(:missing), do: "missing"
  def status_reason(:malformed), do: "malformed"
  def status_reason(:stale), do: "stale"
  def status_reason(:unauthorized), do: "unauthorized"
  def status_reason(:unknown), do: "unknown"

  @spec render_status(auth_status()) :: String.t()
  def render_status(status) when is_atom(status), do: status_reason(status)

  def render_status(_), do: "unknown"
end
