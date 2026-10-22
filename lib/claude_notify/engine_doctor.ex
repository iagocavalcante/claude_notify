defmodule ClaudeNotify.EngineDoctor do
  @moduledoc "Local CLI checks without model turns or credential output."

  def report(opts \\ []) do
    find = Keyword.get(opts, :find, &System.find_executable/1)
    probe = Keyword.get(opts, :probe, &probe/2)

    Enum.map_join(["claude", "codex"], "\n\n", fn engine ->
      case find.(engine) do
        nil ->
          "#{engine}: not installed. Install and sign in on the host, then retry /doctor."

        executable ->
          {version, version_status} = probe.(executable, ["--version"])

          auth_args =
            if engine == "codex", do: ["login", "status"], else: ["auth", "status", "--json"]

          {auth, auth_status} = probe.(executable, auth_args)
          signed_in = auth_status == 0 and signed_in?(auth)
          {_, flags_status} = probe.(executable, help_args(engine))

          safe_version =
            case {version_status, Regex.run(~r/\d+\.\d+\.\d+/, version)} do
              {0, [version]} -> version
              _ -> "version unavailable"
            end

          "#{engine} · #{safe_version}\n" <>
            "Sign-in: #{if signed_in, do: "ready", else: "needs attention — sign in on the host"}\n" <>
            "Launch arguments: #{if flags_status == 0, do: "compatible", else: "unsupported — update the CLI"}"
      end
    end)
  end

  defp signed_in?(auth) do
    case Jason.decode(auth) do
      {:ok, %{"loggedIn" => false}} -> false
      _ -> true
    end
  end

  defp help_args("codex") do
    {_, args} = ClaudeNotify.Engine.Codex.build_command("check", [])
    args ++ ["--help"]
  end

  defp help_args("claude"), do: ["--help"]

  defp probe(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    collect(port, "", System.monotonic_time(:millisecond) + 5_000)
  rescue
    _ -> {"", 1}
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> collect(port, String.slice(output <> data, 0, 32_000), deadline)
      {^port, {:exit_status, status}} -> {output, status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {"", 1}
    end
  end
end
