defmodule ClaudeNotify.ScheduleTest do
  use ExUnit.Case, async: true
  alias ClaudeNotify.Schedule

  test "explicit intervals preserve task text and reject invalid or unbounded schedules" do
    assert {:ok, %{interval: 3600, next_at: 3700, prompt: "check CI\nand report"}} =
             Schedule.parse("every 1h check CI\nand report", 100)

    assert {:ok, %{interval: nil, next_at: 1900}} = Schedule.parse("in 30m inspect", 100)

    for invalid <- [
          "every 0m task",
          "every 99999999d task",
          "tomorrow task",
          "every 1m",
          "every 1m " <> String.duplicate("x", 8001)
        ] do
      assert {:error, _} = Schedule.parse(invalid)
    end
  end
end
