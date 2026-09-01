defmodule ClaudeNotify.TranscriptReaderTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.TranscriptReader

  @moduletag :tmp_dir

  test "tails Claude messages incrementally without replaying old history", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "claude.jsonl")
    File.write!(path, claude_line("old answer") <> "\n")
    assert {:ok, cursor} = TranscriptReader.position(path)

    File.write!(path, claude_line("live update") <> "\n", [:append])

    assert {:ok, ["live update"], next_cursor} =
             TranscriptReader.assistant_messages_since(path, cursor)

    assert next_cursor > cursor

    assert {:ok, [], ^next_cursor} =
             TranscriptReader.assistant_messages_since(path, next_cursor)
  end

  test "parses Codex response_item assistant messages", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "codex.jsonl")
    File.write!(path, codex_line("I found the session gap.") <> "\n")

    assert {:ok, "I found the session gap."} = TranscriptReader.last_assistant_message(path)
  end

  test "keeps one assistant message coherent across multiple text blocks", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "blocks.jsonl")

    File.write!(
      path,
      Jason.encode!(%{
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "First paragraph."},
            %{"type" => "tool_use", "name" => "Read"},
            %{"type" => "text", "text" => "Second paragraph."}
          ]
        }
      }) <> "\n"
    )

    assert {:ok, "First paragraph.\nSecond paragraph."} =
             TranscriptReader.last_assistant_message(path)
  end

  test "first attachment returns only the latest assistant message", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "existing.jsonl")

    File.write!(
      path,
      [claude_line("one"), claude_line("two"), codex_line("three")]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    )

    assert {:ok, ["three"], cursor} =
             TranscriptReader.assistant_messages_since(path, nil)

    assert cursor == File.stat!(path).size
  end

  test "holds an incomplete JSONL line until it is complete", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "partial.jsonl")
    assert :ok = File.write(path, "")
    assert {:ok, cursor} = TranscriptReader.position(path)

    line = codex_line("complete later")
    split = div(byte_size(line), 2)
    File.write!(path, binary_part(line, 0, split), [:append])

    assert {:ok, [], ^cursor} = TranscriptReader.assistant_messages_since(path, cursor)

    File.write!(path, binary_part(line, split, byte_size(line) - split) <> "\n", [:append])

    assert {:ok, ["complete later"], next_cursor} =
             TranscriptReader.assistant_messages_since(path, cursor)

    assert next_cursor == File.stat!(path).size
  end

  defp claude_line(text) do
    Jason.encode!(%{
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}]
      }
    })
  end

  defp codex_line(text) do
    Jason.encode!(%{
      "type" => "response_item",
      "payload" => %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    })
  end
end
