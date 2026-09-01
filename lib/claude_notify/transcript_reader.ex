defmodule ClaudeNotify.TranscriptReader do
  @moduledoc """
  Reads assistant messages from Claude Code and Codex JSONL transcripts.

  Interactive hooks use the byte cursor returned by
  `assistant_messages_since/2` to tail an already-running session without
  replaying its entire chat. Codex documents `transcript_path` as a convenient
  but unstable hook interface, so every parser here is deliberately
  best-effort and callers retain the hook's final assistant message as a
  fallback.
  """

  require Logger

  @initial_tail_bytes 256 * 1024

  @doc "Returns the current append position for a transcript."
  def position(nil), do: :error
  def position(""), do: :error

  def position(transcript_path) do
    case File.stat(transcript_path) do
      {:ok, %{type: :regular, size: size}} -> {:ok, size}
      {:ok, _stat} -> :error
      {:error, _reason} -> :error
    end
  end

  @doc """
  Reads assistant messages appended after `cursor` and returns the next byte
  cursor as `{:ok, messages, cursor}`.

  A missing, invalid, or out-of-range cursor is treated as first attachment:
  only the latest assistant message from a bounded tail is returned, avoiding
  a flood when the service discovers a long-running terminal session.
  """
  def assistant_messages_since(nil, _cursor), do: :error
  def assistant_messages_since("", _cursor), do: :error

  def assistant_messages_since(transcript_path, cursor) do
    with {:ok, %{type: :regular, size: size}} <- File.stat(transcript_path),
         {start, first_attachment?} <- read_start(cursor, size),
         {:ok, data} <- read_from(transcript_path, start) do
      {complete, next_cursor} = complete_jsonl(data, start)

      messages =
        complete
        |> drop_partial_prefix(start, first_attachment?)
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&extract_assistant_texts/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.dedup()
        |> maybe_latest_only(first_attachment?)

      {:ok, messages, next_cursor}
    else
      _ -> :error
    end
  end

  @doc """
  Extracts the last text block from the last assistant message in the transcript.
  Returns `{:ok, text}` or `:error`.
  """
  def last_assistant_message(nil), do: :error
  def last_assistant_message(""), do: :error

  def last_assistant_message(transcript_path) do
    case assistant_messages_since(transcript_path, nil) do
      {:ok, messages, _cursor} ->
        case List.last(messages) do
          nil -> :error
          text -> {:ok, text}
        end

      :error ->
        Logger.warning("TranscriptReader: failed to read #{transcript_path}")
        :error
    end
  end

  defp read_start(cursor, size) when is_integer(cursor) and cursor >= 0 and cursor <= size,
    do: {cursor, false}

  defp read_start(_cursor, size), do: {max(size - @initial_tail_bytes, 0), true}

  defp read_from(path, start) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          with {:ok, _position} <- :file.position(io, start) do
            case IO.binread(io, :eof) do
              data when is_binary(data) -> {:ok, data}
              :eof -> {:ok, ""}
              {:error, reason} -> {:error, reason}
            end
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_jsonl("", start), do: {"", start}

  defp complete_jsonl(data, start) do
    if String.ends_with?(data, "\n") do
      {data, start + byte_size(data)}
    else
      case :binary.matches(data, "\n") do
        [] ->
          {"", start}

        matches ->
          {last_newline, 1} = List.last(matches)
          bytes = last_newline + 1
          {binary_part(data, 0, bytes), start + bytes}
      end
    end
  end

  defp drop_partial_prefix(data, start, true) when start > 0 do
    case :binary.match(data, "\n") do
      {newline, 1} -> binary_part(data, newline + 1, byte_size(data) - newline - 1)
      :nomatch -> ""
    end
  end

  defp drop_partial_prefix(data, _start, _first_attachment?), do: data

  defp maybe_latest_only([], _first_attachment?), do: []
  defp maybe_latest_only(messages, true), do: [List.last(messages)]
  defp maybe_latest_only(messages, false), do: messages

  defp extract_assistant_texts(line) do
    text =
      case Jason.decode(line) do
        {:ok, %{"message" => %{"role" => "assistant", "content" => content}}} ->
          extract_text_from_content(content)

        {:ok,
         %{
           "type" => "response_item",
           "payload" => %{"type" => "message", "role" => "assistant", "content" => content}
         }} ->
          extract_text_from_content(content)

        _ ->
          ""
      end

    if text == "", do: [], else: [text]
  end

  defp extract_text_from_content(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => type} when type in ["text", "output_text"], &1))
    |> Enum.map(& &1["text"])
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n")
  end

  defp extract_text_from_content(content) when is_binary(content) and content != "" do
    content
  end

  defp extract_text_from_content(_), do: ""
end
