defmodule SymphonyElixir.ConfigFilterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ConfigFilter

  @hook_line "hooks.state = { last_seen = \"volatile\" }"

  test "config filter removes inline hooks.state entries" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-elixir-config-filter-inline-#{System.unique_integer([:positive])}")

    source_config = Path.join(workspace, "source.toml")
    safe_config = Path.join([workspace, ".codex", "config.toml"])

    try do
      File.mkdir_p!(workspace)

      File.write!(source_config, """
      model = "gpt-5.3-codex-spark"
      #{@hook_line}
      shell_environment_policy = "inherit=all"
      [projects]
      [mcp_servers]
      """)

      {:ok, command} = ConfigFilter.inject_sandbox_config("codex app-server", workspace, source_config_path: source_config)

      assert safe_config == Path.join([workspace, ".codex", "config.toml"])
      assert String.starts_with?(command, "HOME='#{workspace}' codex app-server")
      assert File.exists?(safe_config)

      filtered = File.read!(safe_config)
      refute String.contains?(filtered, "hooks.state")
      assert String.contains?(filtered, "model = \"gpt-5.3-codex-spark\"")
      assert String.contains?(filtered, "shell_environment_policy = \"inherit=all\"")
    after
      File.rm_rf(workspace)
    end
  end

  test "config filter links host auth into the sandboxed codex home" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-elixir-config-filter-auth-#{System.unique_integer([:positive])}")

    source_config = Path.join(workspace, "source.toml")
    source_auth = Path.join(workspace, "host-auth.json")
    safe_auth = Path.join([workspace, ".codex", "auth.json"])

    try do
      File.mkdir_p!(workspace)
      File.write!(source_config, ~s(model = "gpt-5.5"\n))
      File.write!(source_auth, ~s({"fake":"auth"}))

      {:ok, command} =
        ConfigFilter.inject_sandbox_config("codex app-server", workspace,
          source_config_path: source_config,
          source_auth_path: source_auth
        )

      assert String.starts_with?(command, "HOME='#{workspace}' codex app-server")
      assert File.lstat!(safe_auth).type == :symlink
      assert File.read_link!(safe_auth) == source_auth
    after
      File.rm_rf(workspace)
    end
  end

  test "config filter excludes runtime auth and caches from workspace git status" do
    root =
      Path.join(System.tmp_dir!(), "symphony-elixir-config-filter-excludes-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    source_config = Path.join(root, "host-config.toml")
    source_auth = Path.join(root, "host-auth.json")
    safe_auth = Path.join([workspace, ".codex", "auth.json"])

    try do
      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["-C", workspace, "init", "-q"], stderr_to_stdout: true)

      File.write!(source_config, ~s(model = "gpt-5.5"\n))
      File.write!(source_auth, ~s({"fake":"auth"}))
      File.mkdir_p!(Path.join(workspace, ".hex"))
      File.mkdir_p!(Path.join(workspace, ".mix"))
      File.mkdir_p!(Path.join(workspace, ".cache"))
      File.mkdir_p!(Path.join(workspace, ".docker"))
      File.write!(Path.join([workspace, ".hex", "cache"]), "runtime cache")
      File.write!(Path.join([workspace, ".mix", "archives"]), "runtime cache")
      File.write!(Path.join([workspace, ".cache", "lazy_html.tar.gz"]), "runtime cache")
      File.write!(Path.join([workspace, ".docker", ".token_seed"]), "runtime state")

      assert {:ok, _command} =
               ConfigFilter.inject_sandbox_config("codex app-server", workspace,
                 source_config_path: source_config,
                 source_auth_path: source_auth
               )

      assert File.lstat!(safe_auth).type == :symlink

      exclude = File.read!(Path.join([workspace, ".git", "info", "exclude"]))

      for pattern <- [".codex/", ".hex/", ".mix/", ".cache/", ".docker/"] do
        assert String.contains?(exclude, pattern)
      end

      assert {"", 0} = System.cmd("git", ["-C", workspace, "status", "--porcelain=v1", "-uall"], stderr_to_stdout: true)
    after
      File.rm_rf(root)
    end
  end

  test "config filter drops hooks.state table sections" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-elixir-config-filter-section-#{System.unique_integer([:positive])}")

    source_config = Path.join(workspace, "source.toml")

    try do
      File.mkdir_p!(workspace)

      File.write!(source_config, """
      [hooks]
      enabled = true

      [hooks.state]
      last_seen = "volatile"

      model = "gpt-5.5"
      [mcp_servers]
      """)

      source_contents = File.read!(source_config)
      filtered = ConfigFilter.sanitize_config_contents(source_contents)

      refute String.contains?(filtered, "[hooks.state]")
      refute String.contains?(filtered, "last_seen = \"volatile\"")
      assert String.contains?(filtered, "[hooks]")
      assert String.contains?(filtered, "enabled = true")
    after
      File.rm_rf(workspace)
    end
  end

  test "config filter returns command unchanged when source config is absent" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-elixir-config-filter-missing-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace)

      command = "codex --config model=\"gpt-5.5\" app-server"
      assert {:ok, ^command} = ConfigFilter.inject_sandbox_config(command, workspace, source_config_path: "/nowhere/config.toml")
    after
      File.rm_rf(workspace)
    end
  end
end
