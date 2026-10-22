defmodule ClaudeNotify.AudioTranscriber do
  @moduledoc "Local voice transcription using the installed whisper.cpp CLI. Audio stays on the host."
  def transcribe(path, opts \\ []) do
    model = Keyword.get(opts, :model, System.get_env("CLAUDE_NOTIFY_WHISPER_MODEL"))
    runner = Keyword.get(opts, :runner, &run/3)
    output = path <> ".transcript"
    find = Keyword.get(opts, :find, &System.find_executable/1)

    with true <- is_binary(model) and File.regular?(model),
         executable when is_binary(executable) <- find.("whisper-cli"),
         ffmpeg when is_binary(ffmpeg) <- find.("ffmpeg"),
         :ok <- private_file(path <> ".wav"),
         :ok <- private_file(output <> ".txt"),
         {_, 0} <-
           runner.(
             ffmpeg,
             [
               "-nostdin",
               "-hide_banner",
               "-loglevel",
               "error",
               "-y",
               "-i",
               path,
               "-t",
               "180",
               "-ar",
               "16000",
               "-ac",
               "1",
               "-c:a",
               "pcm_s16le",
               path <> ".wav"
             ],
             []
           ),
         {_, 0} <-
           runner.(
             executable,
             [
               "-m",
               model,
               "-f",
               path <> ".wav",
               "-l",
               "auto",
               "-sns",
               "-otxt",
               "-of",
               output
             ],
             stderr_to_stdout: true
           ),
         {:ok, text} <- File.read(output <> ".txt"),
         text when text != "" <- String.trim(text) do
      File.chmod(output <> ".txt", 0o600)
      {:ok, String.slice(text, 0, 8_000)}
    else
      false -> {:error, :not_configured}
      nil -> {:error, :not_configured}
      _ -> {:error, :transcription_failed}
    end
  rescue
    _ -> {:error, :transcription_failed}
  after
    File.rm(path <> ".transcript.txt")
    File.rm(path <> ".wav")
  end

  defp private_file(path) do
    with :ok <- File.write(path, ""), :ok <- File.chmod(path, 0o600), do: :ok
  end

  defp run(executable, args, _opts) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    await(port, System.monotonic_time(:millisecond) + 120_000)
  end

  defp await(port, deadline) do
    receive do
      {^port, {:data, _}} -> await(port, deadline)
      {^port, {:exit_status, status}} -> {"", status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {"", 1}
    end
  end
end
