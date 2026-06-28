defmodule SymphonyElixir.Codex.AuthKeeperTest do
  use ExUnit.Case

  alias SymphonyElixir.Codex.AuthKeeper

  test "classifies missing auth file" do
    temp_dir = Path.join(System.tmp_dir!(), "sym-exauth-missing-#{System.unique_integer([:positive])}")

    try do
      assert {:missing, nil} = AuthKeeper.status_metadata(Path.join(temp_dir, "missing.json"))
    after
      File.rm_rf(temp_dir)
    end
  end

  test "classifies malformed auth content" do
    temp_dir = Path.join(System.tmp_dir!(), "sym-exauth-malformed-#{System.unique_integer([:positive])}")
    auth_path = Path.join(temp_dir, "auth.json")

    try do
      File.mkdir_p!(temp_dir)
      File.write!(auth_path, "not-json")

      assert {:malformed, _} = AuthKeeper.status_metadata(auth_path)
    after
      File.rm_rf(temp_dir)
    end
  end

  test "classifies fresh valid auth as ok" do
    temp_dir = Path.join(System.tmp_dir!(), "sym-exauth-ok-#{System.unique_integer([:positive])}")
    auth_path = Path.join(temp_dir, "auth.json")

    try do
      File.mkdir_p!(temp_dir)
      File.write!(auth_path, ~s({"access_token":"abc","scope":"default"}))

      assert {:ok, _} = AuthKeeper.status_metadata(auth_path, stale_threshold_ms: 60_000_000)
    after
      File.rm_rf(temp_dir)
    end
  end

  test "classifies stale auth by modification time" do
    temp_dir = Path.join(System.tmp_dir!(), "sym-exauth-stale-#{System.unique_integer([:positive])}")
    auth_path = Path.join(temp_dir, "auth.json")

    try do
      File.mkdir_p!(temp_dir)
      File.write!(auth_path, ~s({"access_token":"abc","scope":"default"}))

      File.touch!(auth_path, System.os_time(:second) - 120)

      assert {:stale, _} = AuthKeeper.status_metadata(auth_path, stale_threshold_ms: 1_000)
    after
      File.rm_rf(temp_dir)
    end
  end

  test "classifies unknown when status path is not a regular file" do
    temp_dir = Path.join(System.tmp_dir!(), "sym-exauth-dir-#{System.unique_integer([:positive])}")
    auth_path = Path.join(temp_dir, "dir")

    try do
      File.mkdir_p!(auth_path)

      assert {:unknown, _} = AuthKeeper.status_metadata(auth_path)
    after
      File.rm_rf(temp_dir)
    end
  end

  test "renders status and reasons without secrets" do
    assert AuthKeeper.render_status(:ok) == "ok"
    assert AuthKeeper.render_status(:malformed) == "malformed"
    assert AuthKeeper.render_status(:unknown) == "unknown"
    assert AuthKeeper.status_reason(:stale) == "stale"
    assert AuthKeeper.status_reason(:unauthorized) == "unauthorized"
  end
end
