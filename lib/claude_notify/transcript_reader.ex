defmodule ClaudeNotify.TranscriptReader do
  @moduledoc """
  Reads the last assistant message from a Claude Code transcript JSONL file.
  """

  require Logger

  @doc """
  Extracts the last text block from the last assistant message in the transcript.
  Returns `{:ok, text}` or `:error`.
  """
  def last_assistant_message(nil), do: :error
  def last_assistant_message(""), do: :error

  def last_assistant_message(transcript_path) do
    case File.read(transcript_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(:error, &extract_assistant_text/1)

      {:error, reason} ->
        Logger.warning("TranscriptReader: failed to read #{transcript_path}: #{reason}")
        :error
    end
  end

  defp extract_assistant_text(line) do
    with {:ok, data} <- Jason.decode(line),
         %{"message" => %{"role" => "assistant", "content" => content}} <- data do
      extract_text_from_content(content)
    else
      _ -> nil
    end
  end

  defp extract_text_from_content(content) when is_list(content) do
    texts =
      content
      |> Enum.filter(&match?(%{"type" => "text"}, &1))
      |> Enum.map(& &1["text"])
      |> Enum.reject(&is_nil/1)

    case List.last(texts) do
      nil -> nil
      text -> {:ok, text}
    end
  end

  defp extract_text_from_content(content) when is_binary(content) and content != "" do
    {:ok, content}
  end

  defp extract_text_from_content(_), do: nil
end
