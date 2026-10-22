defmodule ClaudeNotify.Schedule do
  @moduledoc "Parses explicit, timezone-independent task schedules."
  def parse(text, now \\ System.system_time(:second)) do
    case Regex.run(~r/^(every|in)\s+(\d+)(m|h|d)\s+(.+)$/s, text) do
      [_, kind, amount, unit, prompt] ->
        seconds =
          String.to_integer(amount) * Map.fetch!(%{"m" => 60, "h" => 3600, "d" => 86400}, unit)

        if seconds in 60..31_536_000 and byte_size(prompt) <= 8_000 do
          {:ok,
           %{
             interval: if(kind == "every", do: seconds, else: nil),
             next_at: now + seconds,
             prompt: prompt
           }}
        else
          {:error, :invalid_interval}
        end

      _ ->
        {:error, :invalid_schedule}
    end
  end
end
