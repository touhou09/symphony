defmodule SymphonyElixir.Jira.ADFTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Jira.ADF

  describe "to_text/1" do
    test "returns nil for nil" do
      assert ADF.to_text(nil) == nil
    end

    test "passes a plain string through unchanged" do
      assert ADF.to_text("already plain") == "already plain"
    end

    test "returns nil for a non-map, non-string value" do
      assert ADF.to_text(123) == nil
    end

    test "flattens a rich ADF document across node types" do
      doc = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{"type" => "heading", "content" => [%{"type" => "text", "text" => "Title"}]},
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "Line one"},
              %{"type" => "hardBreak"},
              %{"type" => "text", "text" => "Line two"}
            ]
          },
          %{
            "type" => "bulletList",
            "content" => [
              %{"type" => "listItem", "content" => [%{"type" => "text", "text" => "item a"}]},
              %{"type" => "listItem", "content" => [%{"type" => "text", "text" => "item b"}]}
            ]
          },
          %{"type" => "codeBlock", "content" => [%{"type" => "text", "text" => "x = 1"}]},
          %{"type" => "blockquote", "content" => [%{"type" => "text", "text" => "quote"}]},
          # node with neither content nor text -> empty (fallback clause)
          %{"type" => "rule"}
        ]
      }

      text = ADF.to_text(doc)

      assert text =~ "Title"
      assert text =~ "Line one\nLine two"
      assert text =~ "item a"
      assert text =~ "item b"
      assert text =~ "x = 1"
      assert text =~ "quote"
    end

    test "returns nil for an empty document" do
      assert ADF.to_text(%{"type" => "doc", "content" => []}) == nil
    end

    test "collapses three or more consecutive newlines" do
      doc = %{
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "a"}]},
          %{"type" => "paragraph", "content" => []},
          %{"type" => "paragraph", "content" => []},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "b"}]}
        ]
      }

      assert ADF.to_text(doc) == "a\n\nb"
    end
  end

  describe "from_text/1" do
    test "builds an ADF document preserving line breaks, including blank lines" do
      assert ADF.from_text("first\n\nthird") == %{
               "type" => "doc",
               "version" => 1,
               "content" => [
                 %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "first"}]},
                 %{"type" => "paragraph", "content" => []},
                 %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "third"}]}
               ]
             }
    end
  end
end
