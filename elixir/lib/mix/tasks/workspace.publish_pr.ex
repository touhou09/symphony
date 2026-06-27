defmodule Mix.Tasks.Workspace.PublishPr do
  use Mix.Task

  @shortdoc "Commit, push, and open a GitHub PR for the current workspace branch"

  @moduledoc """
  Commits current workspace changes, pushes the branch, and opens a pull request when one does not already exist.

  This task is intended for use from the `after_complete` workspace hook.

  Usage:

      mix workspace.publish_pr
      mix workspace.publish_pr --repo touhou09/symphony --base main
      mix workspace.publish_pr --title "Implement SYM-123"
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          base: :string,
          body: :string,
          commit_message: :string,
          help: :boolean,
          repo: :string,
          title: :string
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        publish(opts)
    end
  end

  defp publish(opts) do
    branch = current_branch!()
    repo = opts[:repo] || origin_repo!()
    base = opts[:base] || default_branch!(repo)
    title = opts[:title] || default_title(branch)
    commit_message = opts[:commit_message] || title
    body = opts[:body] || default_body(branch)

    ensure_git_identity!()
    maybe_commit_changes!(commit_message)
    push_branch!(branch)

    case open_pull_request_url(repo, branch) do
      nil -> create_pull_request!(repo, base, branch, title, body)
      url -> Mix.shell().info("PR already exists for #{branch}: #{url}")
    end
  end

  defp current_branch! do
    case run!("git", ["branch", "--show-current"]) |> String.trim() do
      "" -> Mix.raise("Current git branch could not be determined")
      branch -> branch
    end
  end

  defp origin_repo! do
    "git"
    |> run!(["remote", "get-url", "origin"])
    |> String.trim()
    |> parse_repo_from_remote()
    |> case do
      nil -> Mix.raise("Could not infer GitHub repo from origin remote")
      repo -> repo
    end
  end

  defp parse_repo_from_remote(remote) when is_binary(remote) do
    cond do
      match = Regex.run(~r/^https:\/\/github\.com\/([^\/]+\/[^\/.]+)(?:\.git)?$/, remote) ->
        Enum.at(match, 1)

      match = Regex.run(~r/^git@github\.com:([^\/]+\/[^\/.]+)(?:\.git)?$/, remote) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  defp default_branch!(repo) do
    case run("gh", ["repo", "view", repo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> "main"
          branch -> branch
        end

      {:error, _reason} ->
        "main"
    end
  end

  defp default_title(branch), do: "Complete #{branch}"

  defp default_body(branch) do
    """
    Automated Symphony handoff for `#{branch}`.

    This PR was opened by the workspace completion hook after the issue left active execution.
    """
    |> String.trim()
  end

  defp ensure_git_identity! do
    ensure_git_config!("user.name", "Symphony Bot")
    ensure_git_config!("user.email", "symphony@example.invalid")
  end

  defp ensure_git_config!(key, fallback) do
    case run("git", ["config", "--get", key]) do
      {:ok, output} ->
        if String.trim(output) == "" do
          set_git_config!(key, fallback)
        else
          :ok
        end

      _ ->
        set_git_config!(key, fallback)
    end
  end

  defp set_git_config!(key, fallback) do
    run!("git", ["config", key, fallback])
    :ok
  end

  defp maybe_commit_changes!(message) do
    case run!("git", ["status", "--porcelain=v1", "-uall"]) |> String.trim() do
      "" ->
        Mix.shell().info("No workspace changes to commit")

      _changes ->
        run!("git", ["add", "-A"])
        run!("git", ["commit", "-m", message])
        Mix.shell().info("Committed workspace changes")
    end
  end

  defp push_branch!(branch) do
    run!("git", ["push", "-u", "origin", branch])
    Mix.shell().info("Pushed branch #{branch}")
  end

  defp open_pull_request_url(repo, branch) do
    case run("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "url",
           "--jq",
           ".[0].url"
         ]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          url -> url
        end

      {:error, _reason} ->
        nil
    end
  end

  defp create_pull_request!(repo, base, branch, title, body) do
    output =
      run!("gh", [
        "pr",
        "create",
        "--repo",
        repo,
        "--base",
        base,
        "--head",
        branch,
        "--title",
        title,
        "--body",
        body
      ])

    url = String.trim(output)
    Mix.shell().info("Created PR for #{branch}: #{url}")
    maybe_add_symphony_label(repo, branch)
  end

  defp maybe_add_symphony_label(repo, branch) do
    case open_pull_request_url(repo, branch) do
      nil ->
        :ok

      url ->
        run("gh", ["pr", "edit", url, "--repo", repo, "--add-label", "symphony"])
        :ok
    end
  end

  defp run!(command, args) do
    case run(command, args) do
      {:ok, output} ->
        output

      {:error, {status, output}} ->
        Mix.raise("#{command} #{Enum.join(args, " ")} failed with exit #{status}: #{String.trim(output)}")
    end
  end

  defp run(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {127, "#{command} not found"}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
