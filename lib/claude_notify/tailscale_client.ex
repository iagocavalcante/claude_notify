defmodule ClaudeNotify.TailscaleClient do
  @moduledoc """
  Manages short-lived Tailscale Serve or Funnel routes for previews.

  The provider can run Tailscale locally or on a configured SSH relay. Relay
  mode keeps the application origin local and forwards only its loopback port
  over SSH before publishing it through Tailscale on the remote host.

  Serve is the secure default: only identities allowed by the tailnet policy can
  connect. Funnel must be selected explicitly because it publishes the route to
  the public internet and does not provide an application-level login prompt.
  """

  require Logger

  @modes [:serve, :funnel]

  def configured?(config) do
    mode(config) in @modes and
      if relay?(config),
        do: not is_nil(ssh_executable(config)),
        else: not is_nil(executable(config))
  end

  def provision(config, _hostname, local_url, _name) do
    with :ok <- require_runtime(config),
         {:ok, hostname} <- hostname(config),
         {:ok, https_port} <- require_port(config, :https_port, :tailscale_port_unavailable),
         {:ok, connector_port, target_url} <- prepare_target(config, local_url) do
      case enable(config, mode(config), https_port, target_url) do
        :ok ->
          suffix = if https_port == 443, do: "", else: ":#{https_port}"

          {:ok,
           %{
             hostname: hostname,
             url: "https://#{hostname}#{suffix}",
             connector_port: connector_port,
             tailscale_mode: mode(config),
             tailscale_https_port: https_port,
             tailscale_remote_port: config[:remote_port]
           }}

        {:error, reason} ->
          close_port(connector_port)
          {:error, reason}
      end
    end
  end

  def cleanup(config, resources) do
    with mode when mode in @modes <- resource(resources, :tailscale_mode) || mode(config),
         port when is_integer(port) <- resource(resources, :tailscale_https_port) do
      case tailscale_command(config, [Atom.to_string(mode), "--yes", "--https=#{port}", "off"]) do
        {_output, 0} ->
          :ok

        {output, status} ->
          Logger.warning(
            "Tailscale preview cleanup failed (status #{status}): #{summarize(output)}"
          )
      end
    else
      _ -> :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("Tailscale preview cleanup failed: #{Exception.message(error)}")
      :ok
  end

  defp prepare_target(config, local_url) do
    if relay?(config) do
      with {:ok, remote_port} <-
             require_port(config, :remote_port, :tailscale_remote_port_unavailable),
           {:ok, local_port} <- local_port(local_url),
           {:ok, connector_port} <- open_reverse_tunnel(config, local_port, remote_port) do
        {:ok, connector_port, "http://127.0.0.1:#{remote_port}"}
      end
    else
      {:ok, nil, local_url}
    end
  end

  defp enable(config, mode, port, target_url) do
    args = [Atom.to_string(mode), "--bg", "--yes", "--https=#{port}", target_url]

    case tailscale_command(config, args) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:tailscale_command_failed, status, summarize(output)}}
    end
  rescue
    error -> {:error, {:tailscale_start_failed, Exception.message(error)}}
  end

  defp hostname(config) do
    case tailscale_command(config, ["status", "--json"]) do
      {output, 0} ->
        with {:ok, decoded} <- Jason.decode(output),
             "Running" <- decoded["BackendState"],
             dns_name when is_binary(dns_name) <- get_in(decoded, ["Self", "DNSName"]),
             hostname when hostname != "" <- String.trim_trailing(dns_name, ".") do
          {:ok, hostname}
        else
          "NeedsLogin" -> {:error, :tailscale_needs_login}
          _ -> {:error, :tailscale_hostname_unavailable}
        end

      {output, status} ->
        {:error, {:tailscale_status_failed, status, summarize(output)}}
    end
  rescue
    error -> {:error, {:tailscale_status_failed, Exception.message(error)}}
  end

  defp tailscale_command(config, args) do
    if relay?(config) do
      ssh = ssh_executable(config) || raise "SSH executable not found"

      remote_command =
        Enum.map_join([config[:tailscale_path] || "tailscale" | args], " ", &shell_escape/1)

      System.cmd(ssh, [config.ssh_host, remote_command], stderr_to_stdout: true)
    else
      tailscale = executable(config) || raise "Tailscale executable not found"
      System.cmd(tailscale, args, stderr_to_stdout: true)
    end
  end

  defp open_reverse_tunnel(config, local_port, remote_port) do
    ssh = ssh_executable(config)

    port =
      Port.open({:spawn_executable, ssh}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-N",
          "-T",
          "-o",
          "BatchMode=yes",
          "-o",
          "ExitOnForwardFailure=yes",
          "-o",
          "ServerAliveInterval=15",
          "-o",
          "ServerAliveCountMax=3",
          "-R",
          "127.0.0.1:#{remote_port}:127.0.0.1:#{local_port}",
          config.ssh_host
        ]
      ])

    Process.sleep(500)

    if Port.info(port) do
      {:ok, port}
    else
      {:error, :ssh_relay_exited}
    end
  rescue
    error -> {:error, {:ssh_relay_start_failed, Exception.message(error)}}
  end

  defp require_runtime(config) do
    case if relay?(config), do: ssh_executable(config), else: executable(config) do
      nil ->
        name =
          if relay?(config),
            do: config[:ssh_path] || "ssh",
            else: config[:tailscale_path] || "tailscale"

        {:error, {:executable_not_found, name}}

      _path ->
        :ok
    end
  end

  defp require_port(config, key, error) do
    case config[key] do
      port when is_integer(port) and port > 0 and port < 65_536 -> {:ok, port}
      _ -> {:error, error}
    end
  end

  defp local_port(local_url) do
    case URI.parse(local_url) do
      %URI{host: host, port: port} when host in ["127.0.0.1", "localhost"] and is_integer(port) ->
        {:ok, port}

      _ ->
        {:error, :invalid_preview_origin}
    end
  end

  defp executable(config), do: System.find_executable(config[:tailscale_path] || "tailscale")
  defp ssh_executable(config), do: System.find_executable(config[:ssh_path] || "ssh")

  defp relay?(config) do
    is_binary(config[:ssh_host]) and String.trim(config[:ssh_host]) != ""
  end

  defp mode(config) do
    case config[:mode] do
      "funnel" -> :funnel
      :funnel -> :funnel
      _ -> :serve
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp resource(resources, key) when is_map(resources), do: Map.get(resources, key)
  defp resource(_, _), do: nil

  defp summarize(output) do
    output
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 300)
  end
end
