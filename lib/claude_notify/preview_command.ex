defmodule ClaudeNotify.PreviewCommand do
  @moduledoc """
  Resolves the local web-server command for a preview worktree.

  Projects can define `.claude-notify.json` with a `preview.command` array.
  `${PORT}` and `${HOST}` placeholders are expanded without invoking a shell.
  Common JavaScript, Phoenix, and static HTML projects are detected when no
  explicit command is present.
  """

  @config_file ".claude-notify.json"
  @host "127.0.0.1"

  def resolve(worktree, port) when is_binary(worktree) and is_integer(port) do
    with :error <- configured_command(worktree, port),
         :error <- javascript_command(worktree, port),
         :error <- phoenix_command(worktree, port),
         :error <- static_command(worktree, port) do
      {:error, :preview_command_not_found}
    end
  end

  defp configured_command(worktree, port) do
    path = Path.join(worktree, @config_file)

    with {:ok, body} <- File.read(path),
         {:ok, config} <- Jason.decode(body),
         command when is_list(command) <- get_in(config, ["preview", "command"]),
         [executable | args] <- Enum.map(command, &expand(&1, port)),
         true <- Enum.all?([executable | args], &is_binary/1) do
      build(executable, args, port, :configured)
    else
      _ -> :error
    end
  end

  defp javascript_command(worktree, port) do
    path = Path.join(worktree, "package.json")

    with {:ok, body} <- File.read(path),
         {:ok, package} <- Jason.decode(body),
         scripts when is_map(scripts) <- package["scripts"],
         script when is_binary(script) <- preferred_script(scripts) do
      {executable, base_args} = package_manager(worktree, script)
      args = base_args ++ framework_args(package, port)
      build(executable, args, port, {:package_script, script})
    else
      _ -> :error
    end
  end

  defp phoenix_command(worktree, port) do
    if File.exists?(Path.join(worktree, "mix.exs")) do
      build("mix", ["phx.server"], port, :phoenix)
    else
      :error
    end
  end

  defp static_command(worktree, port) do
    if File.exists?(Path.join(worktree, "index.html")) do
      build(
        "python3",
        ["-m", "http.server", Integer.to_string(port), "--bind", @host],
        port,
        :static_html
      )
    else
      :error
    end
  end

  defp preferred_script(scripts) do
    Enum.find(["dev", "start", "preview"], &is_binary(scripts[&1]))
  end

  defp package_manager(worktree, script) do
    cond do
      File.exists?(Path.join(worktree, "bun.lock")) or
          File.exists?(Path.join(worktree, "bun.lockb")) ->
        {"bun", ["run", script]}

      File.exists?(Path.join(worktree, "pnpm-lock.yaml")) ->
        {"pnpm", ["run", script]}

      File.exists?(Path.join(worktree, "yarn.lock")) ->
        {"yarn", ["run", script]}

      true ->
        {"npm", ["run", script, "--"]}
    end
  end

  defp framework_args(package, port) do
    deps = Map.merge(package["dependencies"] || %{}, package["devDependencies"] || %{})
    port = Integer.to_string(port)

    cond do
      is_binary(deps["next"]) ->
        ["--hostname", @host, "--port", port]

      Enum.any?(["vite", "astro", "@sveltejs/kit"], &is_binary(deps[&1])) ->
        ["--host", @host, "--port", port]

      true ->
        []
    end
  end

  defp build(executable, args, port, source) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      path ->
        {:ok,
         %{
           executable: path,
           args: args,
           env: [
             {"PORT", Integer.to_string(port)},
             {"HOST", @host},
             {"PHX_SERVER", "true"}
           ],
           source: source
         }}
    end
  end

  defp expand(value, port) when is_binary(value) do
    value
    |> String.replace("${PORT}", Integer.to_string(port))
    |> String.replace("${HOST}", @host)
  end

  defp expand(value, _port), do: value
end
