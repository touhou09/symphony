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
    if github_token_env?() do
      with_github_askpass(fn askpass_path ->
        run!("git", ["push", "-u", "origin", branch], env: [{"GIT_ASKPASS", askpass_path}, {"GIT_TERMINAL_PROMPT", "0"}])
      end)
    else
      run!("git", ["push", "-u", "origin", branch])
    end

    Mix.shell().info("Pushed branch #{branch}")
  end

  defp github_token_env? do
    env_present?("GH_TOKEN") or env_present?("GITHUB_TOKEN")
  end

  defp env_present?(key) do
    case System.get_env(key) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp with_github_askpass(fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-git-askpass-#{System.unique_integer([:positive, :monotonic])}.sh"
      )

    File.write!(path, github_askpass_script())
    File.chmod!(path, 0o700)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp github_askpass_script do
    """
    #!/bin/sh
    case "$1" in
      *Username*) printf '%s\\n' 'x-access-token' ;;
      *Password*) printf '%s\\n' "${GH_TOKEN:-$GITHUB_TOKEN}" ;;
      *) printf '\\n' ;;
    esac
    """
  end

  defp open_pull_request_url(repo, branch) do
    cond do
      gh_available?() ->
        open_pull_request_url_with_gh(repo, branch)

      github_token_env?() ->
        open_pull_request_with_api(repo, branch)

      true ->
        nil
    end
  end

  defp create_pull_request!(repo, base, branch, title, body) do
    cond do
      gh_available?() ->
        create_pull_request_with_gh!(repo, base, branch, title, body)

      github_token_env?() ->
        create_pull_request_with_api!(repo, base, branch, title, body)

      true ->
        Mix.raise("GitHub PR creation requires gh or GH_TOKEN/GITHUB_TOKEN")
    end
  end

  defp open_pull_request_url_with_gh(repo, branch) do
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

  defp create_pull_request_with_gh!(repo, base, branch, title, body) do
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
    if gh_available?() do
      case open_pull_request_url_with_gh(repo, branch) do
        nil ->
          :ok

        url ->
          run("gh", ["pr", "edit", url, "--repo", repo, "--add-label", "symphony"])
          :ok
      end
    else
      :ok
    end
  end

  defp open_pull_request_with_api(repo, branch) do
    token = github_token!()
    {owner, _name} = github_repo_parts!(repo)

    case github_api_request(:get, repo, "/pulls",
           token: token,
           params: [state: "open", head: "#{owner}:#{branch}"]
         ) do
      {:ok, pulls} when is_list(pulls) ->
        pulls
        |> List.first()
        |> case do
          %{"html_url" => url} when is_binary(url) -> url
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp create_pull_request_with_api!(repo, base, branch, title, body) do
    token = github_token!()
    {owner, _name} = github_repo_parts!(repo)

    payload = %{
      title: title,
      body: body,
      base: base,
      head: "#{owner}:#{branch}"
    }

    case github_api_request(:post, repo, "/pulls", token: token, json: payload) do
      {:ok, %{"html_url" => url, "number" => number}} ->
        Mix.shell().info("Created PR for #{branch}: #{url}")
        add_symphony_label_with_api(repo, number, token)

      {:ok, %{"html_url" => url}} ->
        Mix.shell().info("Created PR for #{branch}: #{url}")

      {:error, reason} ->
        Mix.raise("GitHub PR creation failed: #{reason}")
    end
  end

  defp add_symphony_label_with_api(repo, number, token) when is_integer(number) do
    github_api_request(:post, repo, "/issues/#{number}/labels",
      token: token,
      json: %{labels: ["symphony"]}
    )

    :ok
  end

  defp add_symphony_label_with_api(_repo, _number, _token), do: :ok

  defp github_api_request(method, repo, path, opts) do
    {owner, name} = github_repo_parts!(repo)
    base_url = System.get_env("SYMPHONY_GITHUB_API_URL") || "https://api.github.com"
    url = "#{String.trim_trailing(base_url, "/")}/repos/#{owner}/#{name}#{path}"
    token = Keyword.fetch!(opts, :token)

    req_opts =
      [
        method: method,
        url: url,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"authorization", "Bearer #{token}"},
          {"user-agent", "symphony"},
          {"x-github-api-version", "2022-11-28"}
        ],
        params: Keyword.get(opts, :params, [])
      ]
      |> maybe_put_json(opts)

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status} #{github_error_message(body)}"}

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  defp maybe_put_json(req_opts, opts) do
    case Keyword.fetch(opts, :json) do
      {:ok, json} -> Keyword.put(req_opts, :json, json)
      :error -> req_opts
    end
  end

  defp github_error_message(%{"message" => message}) when is_binary(message), do: message
  defp github_error_message(body) when is_binary(body), do: body
  defp github_error_message(body), do: inspect(body)

  defp github_repo_parts!(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> {owner, name}
      _ -> Mix.raise("Invalid GitHub repo #{inspect(repo)}")
    end
  end

  defp github_token! do
    github_token() || Mix.raise("GH_TOKEN/GITHUB_TOKEN is required for GitHub API publishing")
  end

  defp github_token do
    ["GH_TOKEN", "GITHUB_TOKEN"]
    |> Enum.find_value(fn key ->
      case System.get_env(key) do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        _ ->
          nil
      end
    end)
  end

  defp gh_available? do
    not is_nil(System.find_executable("gh"))
  end

  defp run!(command, args, opts \\ []) do
    case run(command, args, opts) do
      {:ok, output} ->
        output

      {:error, {status, output}} ->
        Mix.raise("#{command} #{Enum.join(args, " ")} failed with exit #{status}: #{String.trim(output)}")
    end
  end

  defp run(command, args, opts \\ []) do
    case System.find_executable(command) do
      nil ->
        {:error, {127, "#{command} not found"}}

      path ->
        case System.cmd(path, args, Keyword.merge([stderr_to_stdout: true], opts)) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
