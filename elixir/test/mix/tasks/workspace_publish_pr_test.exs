defmodule Mix.Tasks.Workspace.PublishPrTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workspace.PublishPr

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("workspace.publish_pr")
    :ok
  end

  test "pushes with GitHub token askpass without exposing the token" do
    with_fake_binaries(fn log_path ->
      with_env(%{"GH_TOKEN" => "secret-test-token", "GITHUB_TOKEN" => ""}, fn ->
        output =
          capture_io(fn ->
            PublishPr.run(["--repo", "touhou09/symphony", "--base", "dev"])
          end)

        assert output =~ "Pushed branch sym-13-no-diff-guard"
        assert output =~ "Created PR for sym-13-no-diff-guard"

        log = File.read!(log_path)
        assert log =~ "git push -u origin sym-13-no-diff-guard"
        assert log =~ "askpass-user=x-access-token"
        assert log =~ "askpass-password-present=yes"
        refute log =~ "secret-test-token"
      end)
    end)
  end

  test "pushes normally when no GitHub token env is present" do
    with_fake_binaries(fn log_path ->
      with_env(%{"GH_TOKEN" => "", "GITHUB_TOKEN" => ""}, fn ->
        capture_io(fn ->
          PublishPr.run(["--repo", "touhou09/symphony", "--base", "dev"])
        end)

        log = File.read!(log_path)
        assert log =~ "git push -u origin sym-13-no-diff-guard"
        assert log =~ "askpass=missing"
      end)
    end)
  end

  test "refuses to publish from the base branch before pushing" do
    with_fake_binaries(fn log_path ->
      with_env(%{"FAKE_GIT_BRANCH" => "dev", "GH_TOKEN" => "", "GITHUB_TOKEN" => ""}, fn ->
        assert_raise Mix.Error, ~r/Refusing to publish PR from base branch dev/, fn ->
          capture_io(fn ->
            PublishPr.run(["--repo", "touhou09/symphony", "--base", "dev"])
          end)
        end

        log = File.read!(log_path)
        refute log =~ "git add -A"
        refute log =~ "git commit"
        refute log =~ "git push"
        refute log =~ "gh pr create"
      end)
    end)
  end

  test "skips evidence-only publish when existing PR head is already green" do
    with_fake_binaries(fn log_path ->
      with_env(
        %{
          "FAKE_GIT_STATUS" => "evidence-only",
          "FAKE_GH_PR_LIST" => "green-existing",
          "GH_TOKEN" => "",
          "GITHUB_TOKEN" => ""
        },
        fn ->
          output =
            capture_io(fn ->
              PublishPr.run(["--repo", "touhou09/symphony", "--base", "dev"])
            end)

          assert output =~ "PR already green for current HEAD"

          log = File.read!(log_path)
          refute log =~ "git add -A"
          refute log =~ "git commit"
          refute log =~ "git push"
          refute log =~ "gh pr create"
        end
      )
    end)
  end

  test "still publishes substantive changes even when existing PR head is green" do
    with_fake_binaries(fn log_path ->
      with_env(
        %{
          "FAKE_GIT_STATUS" => "substantive",
          "FAKE_GH_PR_LIST" => "green-existing",
          "GH_TOKEN" => "",
          "GITHUB_TOKEN" => ""
        },
        fn ->
          capture_io(fn ->
            PublishPr.run(["--repo", "touhou09/symphony", "--base", "dev"])
          end)

          log = File.read!(log_path)
          assert log =~ "git add -A"
          assert log =~ "git commit -m Complete sym-13-no-diff-guard"
          assert log =~ "git push -u origin sym-13-no-diff-guard"
        end
      )
    end)
  end

  defp with_fake_binaries(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-publish-pr-task-test-#{unique}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "commands.log")

    try do
      File.rm_rf!(root)
      File.mkdir_p!(bin_dir)
      File.write!(log_path, "")

      write_executable!(Path.join(bin_dir, "git"), fake_git_script())
      write_executable!(Path.join(bin_dir, "gh"), fake_gh_script())

      original_path = System.get_env("PATH") || ""

      with_env(
        %{
          "COMMAND_LOG" => log_path,
          "PATH" => Enum.join([bin_dir, original_path], ":")
        },
        fn -> fun.(log_path) end
      )
    after
      File.rm_rf!(root)
    end
  end

  defp write_executable!(path, script) do
    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp fake_git_script do
    """
    #!/bin/sh
    printf 'git %s\\n' "$*" >> "$COMMAND_LOG"

    if [ "$1" = "branch" ] && [ "$2" = "--show-current" ]; then
      if [ -n "$FAKE_GIT_BRANCH" ]; then
        printf '%s\\n' "$FAKE_GIT_BRANCH"
        exit 0
      fi
      printf 'sym-13-no-diff-guard\\n'
      exit 0
    fi

    if [ "$1" = "config" ] && [ "$2" = "--get" ]; then
      printf 'configured\\n'
      exit 0
    fi

    if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
      printf 'abc123green\\n'
      exit 0
    fi

    if [ "$1" = "status" ]; then
      case "$FAKE_GIT_STATUS" in
        evidence-only)
          printf ' M docs/codex-squad-evidence.md\\n'
          ;;
        substantive)
          printf ' M elixir/lib/symphony_elixir/orchestrator.ex\\n'
          ;;
      esac
      exit 0
    fi

    if [ "$1" = "add" ]; then
      exit 0
    fi

    if [ "$1" = "commit" ]; then
      exit 0
    fi

    if [ "$1" = "push" ]; then
      if [ -n "$GIT_ASKPASS" ]; then
        user="$("$GIT_ASKPASS" 'Username for https://github.com')"
        pass="$("$GIT_ASKPASS" 'Password for https://github.com')"
        printf 'askpass-user=%s\\n' "$user" >> "$COMMAND_LOG"
        if [ -n "$pass" ]; then
          printf 'askpass-password-present=yes\\n' >> "$COMMAND_LOG"
        else
          printf 'askpass-password-present=no\\n' >> "$COMMAND_LOG"
        fi
        test "$pass" = "$GH_TOKEN" || exit 42
      else
        printf 'askpass=missing\\n' >> "$COMMAND_LOG"
      fi

      exit 0
    fi

    exit 99
    """
  end

  defp fake_gh_script do
    """
    #!/bin/sh
    printf 'gh %s\\n' "$*" >> "$COMMAND_LOG"

    if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
      if [ "$FAKE_GH_PR_LIST" = "green-existing" ]; then
        printf '%s\\n' '[{"url":"https://github.com/touhou09/symphony/pull/28","headRefOid":"abc123green","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}]'
      fi
      exit 0
    fi

    if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
      printf 'https://github.com/touhou09/symphony/pull/13\\n'
      exit 0
    fi

    if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
      exit 0
    fi

    exit 99
    """
  end

  defp with_env(overrides, fun) do
    keys = Map.keys(overrides)
    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
