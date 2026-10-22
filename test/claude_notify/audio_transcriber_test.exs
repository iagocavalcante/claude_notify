defmodule ClaudeNotify.AudioTranscriberTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  test "missing local model gives actionable configuration error", %{tmp_dir: dir} do
    assert {:error, :not_configured} =
             ClaudeNotify.AudioTranscriber.transcribe(Path.join(dir, "voice.ogg"), model: nil)
  end

  test "reads trimmed output and removes temporary transcripts", %{tmp_dir: dir} do
    model = Path.join(dir, "model.bin")
    path = Path.join(dir, "voice.ogg")
    File.write!(model, "test")

    runner = fn _, args, _ ->
      if "-otxt" in args do
        assert "-l" in args and "auto" in args
        File.write!(path <> ".transcript.txt", " Hello from Telegram \n")
      end

      {"", 0}
    end

    assert {:ok, "Hello from Telegram"} =
             ClaudeNotify.AudioTranscriber.transcribe(path,
               model: model,
               runner: runner,
               find: fn name -> name end
             )

    refute File.exists?(path <> ".transcript.txt")
  end
end
