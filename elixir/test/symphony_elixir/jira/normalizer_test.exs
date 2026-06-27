defmodule SymphonyElixir.Jira.NormalizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Jira.Normalizer
  alias SymphonyElixir.Linear.Issue

  @endpoint "https://yujin3178.atlassian.net"

  defp issue(fields) do
    %{"id" => "10001", "key" => "SYM-1", "fields" => fields}
  end

  test "returns nil for a non-map payload" do
    assert Normalizer.normalize_issue("nope", nil, @endpoint) == nil
  end

  test "normalizes a full Jira issue into the shared Issue struct" do
    raw =
      issue(%{
        "summary" => "Build the thing",
        "description" => %{
          "type" => "doc",
          "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "desc"}]}]
        },
        "priority" => %{"name" => "High"},
        "status" => %{"name" => "In Progress"},
        "assignee" => %{"accountId" => "acc-123"},
        "labels" => ["Backend", " ai ", "", 42],
        "issuelinks" => [
          %{
            "type" => %{"inward" => "is blocked by"},
            "inwardIssue" => %{"id" => "9", "key" => "SYM-9", "fields" => %{"status" => %{"name" => "Todo"}}}
          },
          %{"type" => %{"inward" => "relates to"}, "inwardIssue" => %{"id" => "8", "key" => "SYM-8"}},
          %{"unexpected" => true}
        ],
        "created" => "2026-06-26T12:34:56.000+09:00",
        "updated" => "2026-06-26T12:34:56.000+0900"
      })

    assert %Issue{
             id: "10001",
             identifier: "SYM-1",
             title: "Build the thing",
             description: "desc",
             priority: 2,
             state: "In Progress",
             branch_name: nil,
             url: "https://yujin3178.atlassian.net/browse/SYM-1",
             assignee_id: "acc-123",
             labels: ["backend", "ai"],
             assigned_to_worker: true,
             blocked_by: [%{id: "9", identifier: "SYM-9", state: "Todo"}]
           } = Normalizer.normalize_issue(raw, nil, @endpoint)
  end

  describe "priority mapping" do
    for {name, expected} <- [{"Highest", 1}, {"High", 2}, {"Medium", 3}, {"Low", 4}, {"Lowest", 5}] do
      test "maps #{name} -> #{expected}" do
        raw = issue(%{"priority" => %{"name" => unquote(name)}})
        assert %Issue{priority: unquote(expected)} = Normalizer.normalize_issue(raw, nil, @endpoint)
      end
    end

    test "unknown priority name -> nil" do
      raw = issue(%{"priority" => %{"name" => "Whenever"}})
      assert %Issue{priority: nil} = Normalizer.normalize_issue(raw, nil, @endpoint)
    end

    test "missing priority -> nil" do
      assert %Issue{priority: nil} = Normalizer.normalize_issue(issue(%{}), nil, @endpoint)
    end
  end

  describe "assigned_to_worker?" do
    test "no assignee filter -> true" do
      raw = issue(%{"assignee" => %{"accountId" => "acc-1"}})
      assert %Issue{assigned_to_worker: true} = Normalizer.normalize_issue(raw, nil, @endpoint)
    end

    test "accountId in match set -> true" do
      filter = %{match_values: MapSet.new(["acc-1"])}
      raw = issue(%{"assignee" => %{"accountId" => "acc-1"}})
      assert %Issue{assigned_to_worker: true} = Normalizer.normalize_issue(raw, filter, @endpoint)
    end

    test "accountId not in match set -> false" do
      filter = %{match_values: MapSet.new(["acc-other"])}
      raw = issue(%{"assignee" => %{"accountId" => "acc-1"}})
      assert %Issue{assigned_to_worker: false} = Normalizer.normalize_issue(raw, filter, @endpoint)
    end

    test "no assignee but filter present -> false" do
      filter = %{match_values: MapSet.new(["acc-1"])}
      raw = issue(%{"assignee" => nil})

      assert %Issue{assigned_to_worker: false, assignee_id: nil} =
               Normalizer.normalize_issue(raw, filter, @endpoint)
    end

    test "malformed filter (no match_values) -> false" do
      raw = issue(%{"assignee" => %{"accountId" => "acc-1"}})

      assert %Issue{assigned_to_worker: false} =
               Normalizer.normalize_issue(raw, %{configured_assignee: "x"}, @endpoint)
    end
  end

  describe "labels / blockers / url edge cases" do
    test "missing labels and issuelinks default to empty lists" do
      assert %Issue{labels: [], blocked_by: []} = Normalizer.normalize_issue(issue(%{}), nil, @endpoint)
    end

    test "nil endpoint yields nil url" do
      assert %Issue{url: nil} = Normalizer.normalize_issue(issue(%{}), nil, nil)
    end
  end

  describe "datetime parsing" do
    test "parses extended-offset timestamps" do
      raw = issue(%{"created" => "2026-06-26T00:00:00.000+09:00"})
      assert %Issue{created_at: %DateTime{}} = Normalizer.normalize_issue(raw, nil, @endpoint)
    end

    test "parses basic-offset timestamps" do
      raw = issue(%{"created" => "2026-06-26T00:00:00.000+0900"})
      assert %Issue{created_at: %DateTime{}} = Normalizer.normalize_issue(raw, nil, @endpoint)
    end

    test "invalid and missing timestamps -> nil" do
      raw = issue(%{"created" => "not-a-date", "updated" => 123})
      assert %Issue{created_at: nil, updated_at: nil} = Normalizer.normalize_issue(raw, nil, @endpoint)
    end
  end
end
