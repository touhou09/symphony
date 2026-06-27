defmodule Mix.Tasks.Ticket.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ticket.Check

  setup do
    Mix.Task.reenable("ticket.check")
    :ok
  end

  test "validates a strict ticket file" do
    in_temp_project(fn ->
      File.mkdir_p!("docs")
      File.write!("docs/ticket.md", valid_ticket())

      output = capture_io(fn -> assert :ok = Check.run(["--file", "docs/ticket.md", "--strict"]) end)

      assert output =~ "ticket.check: ticket content contract OK"
    end)
  end

  test "raises when strict ticket content is missing validation" do
    in_temp_project(fn ->
      File.mkdir_p!("docs")
      File.write!("docs/ticket.md", String.replace(valid_ticket(), "## Validation\n\n- [ ] Run tests.\n", ""))

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/ticket.check failed with/, fn ->
            Check.run(["--file", "docs/ticket.md", "--strict"])
          end
        end)

      assert error_output =~ "missing section ## Validation"
    end)
  end

  test "loads ticket content rules from workflow" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", """
      ---
      ticket:
        required_description_sections:
          - Background
          - Validation
        require_validation_checkboxes: true
      ---
      Prompt.
      """)

      File.mkdir_p!("docs")

      File.write!("docs/ticket.md", """
      ## Background

      Context.

      ## Test Plan

      - [ ] Run the configured check.
      """)

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--file", "docs/ticket.md", "--workflow", "WORKFLOW.md"])
        end)

      assert output =~ "ticket.check: ticket content contract OK"
    end)
  end

  defp valid_ticket do
    """
    ## Background

    Context.

    ## Scope

    - Include the target change.

    ## Acceptance Criteria

    - [ ] The behavior is implemented.

    ## Validation

    - [ ] Run tests.
    """
  end

  defp in_temp_project(fun) do
    root = Path.join(System.tmp_dir!(), "ticket-check-task-test-#{System.unique_integer([:positive, :monotonic])}")
    original_cwd = File.cwd!()

    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      File.cd!(root, fun)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
      Application.delete_env(:symphony_elixir, :workflow_file_path)
    end
  end
end
