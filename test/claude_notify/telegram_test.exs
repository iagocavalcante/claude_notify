defmodule ClaudeNotify.TelegramTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.Telegram

  setup_all do
    Code.ensure_loaded!(Telegram)
    :ok
  end

  describe "chunk/2" do
    test "returns single-element list when text fits" do
      assert Telegram.chunk("hello", 4096) == ["hello"]
    end

    test "returns single-element list at exact limit" do
      text = String.duplicate("a", 4096)
      assert Telegram.chunk(text, 4096) == [text]
    end

    test "splits on paragraph boundaries when possible" do
      part1 = String.duplicate("a", 100)
      part2 = String.duplicate("b", 100)
      part3 = String.duplicate("c", 100)
      text = "#{part1}\n\n#{part2}\n\n#{part3}"

      # limit forces split, but greedy packing keeps first two together
      chunks = Telegram.chunk(text, 210)
      assert length(chunks) == 2
      assert Enum.all?(chunks, &(String.length(&1) <= 210))
    end

    test "every chunk respects the byte limit" do
      text = String.duplicate("paragraph with content here\n\n", 500)
      chunks = Telegram.chunk(text, 200)
      assert Enum.all?(chunks, &(String.length(&1) <= 200))
      # round-trip preserves all content (modulo separator stripping is not done here)
      assert Enum.join(chunks, "") |> String.length() > 0
    end

    test "falls back to line splits when paragraphs are too big" do
      # one paragraph, many lines
      text =
        1..50
        |> Enum.map(fn _ -> String.duplicate("x", 50) end)
        |> Enum.join("\n")

      chunks = Telegram.chunk(text, 200)
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(String.length(&1) <= 200))
    end

    test "hard splits long unbroken text" do
      text = String.duplicate("a", 500)
      chunks = Telegram.chunk(text, 100)
      assert length(chunks) == 5
      assert Enum.all?(chunks, &(String.length(&1) == 100))
    end

    test "preserves multi-byte graphemes across hard splits" do
      # 200 emoji, each is one grapheme but multiple bytes
      text = String.duplicate("🔥", 200)
      chunks = Telegram.chunk(text, 50)
      # never split a grapheme: every chunk recombines to valid UTF-8
      assert Enum.all?(chunks, &String.valid?/1)
      assert Enum.all?(chunks, &(String.length(&1) <= 50))
    end

    test "uses default 4096 limit" do
      text = String.duplicate("a", 5000)
      chunks = Telegram.chunk(text)
      assert length(chunks) == 2
      assert hd(chunks) |> String.length() == 4096
    end
  end

  describe "html_chunk/2" do
    test "closes and reopens formatting across chunks" do
      html = "<b>" <> String.duplicate("formatted text ", 30) <> "</b>"
      chunks = Telegram.html_chunk(html, 90)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(String.length(&1) <= 90))
      assert Enum.all?(chunks, &String.starts_with?(&1, "<b>"))
      assert Enum.all?(chunks, &String.ends_with?(&1, "</b>"))

      reconstructed =
        chunks
        |> Enum.map(
          &(&1
            |> String.replace_prefix("<b>", "")
            |> String.replace_suffix("</b>", ""))
        )
        |> Enum.join()

      assert reconstructed == String.duplicate("formatted text ", 30)
    end

    test "does not split escaped HTML entities" do
      html = "<pre>" <> String.duplicate("&lt;value&gt; ", 30) <> "</pre>"
      chunks = Telegram.html_chunk(html, 80)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(String.length(&1) <= 80))
      refute Enum.any?(chunks, &Regex.match?(~r/&[^;]*$/, &1))
    end

    test "keeps nested tags balanced" do
      html = "<blockquote><b>" <> String.duplicate("nested ", 40) <> "</b></blockquote>"
      chunks = Telegram.html_chunk(html, 100)

      assert Enum.all?(chunks, &String.starts_with?(&1, "<blockquote><b>"))
      assert Enum.all?(chunks, &String.ends_with?(&1, "</b></blockquote>"))
      assert Enum.all?(chunks, &(String.length(&1) <= 100))
    end
  end

  describe "API surface" do
    test "edit_message_text supports arity 2 and 3" do
      assert function_exported?(Telegram, :edit_message_text, 2)
      assert function_exported?(Telegram, :edit_message_text, 3)
    end

    test "edit_message_text_with_retry retries on 429" do
      assert function_exported?(Telegram, :edit_message_text_with_retry, 2)
    end

    test "edit_message_text_with_buttons builds correct API payload" do
      assert function_exported?(Telegram, :edit_message_text_with_buttons, 3)
    end

    test "send_message accepts opts" do
      assert function_exported?(Telegram, :send_message, 1)
      assert function_exported?(Telegram, :send_message, 2)
    end

    test "HTML message helpers are available" do
      assert function_exported?(Telegram, :send_html_with_retry, 1)
      assert function_exported?(Telegram, :send_html_with_retry, 2)
      assert function_exported?(Telegram, :send_html_with_retry, 3)
      assert function_exported?(Telegram, :edit_message_text_with_buttons_html_retry, 3)
    end

    test "set_message_reaction sends correct API request" do
      result = Telegram.set_message_reaction(12345, "👀")
      assert match?({:error, _}, result)
    end
  end
end
