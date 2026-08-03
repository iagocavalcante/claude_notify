defmodule ClaudeNotify.PreviewManager do
  @moduledoc """
  Owns ephemeral local web servers and their remote-access previews.

  Cloudflare Access and Tailscale are provider implementations behind the same
  lifecycle. Each preview is tied to a dispatcher job worktree, expires
  automatically, and is removed from its provider when its origin or connector
  process exits.
  """

  use GenServer

  require Logger

  alias ClaudeNotify.{CloudflareClient, PreviewCommand, TailscaleClient}

  @origin_attempts 60
  @origin_retry_ms 250

  defmodule Preview do
    @moduledoc false
    defstruct [
      :id,
      :job_id,
      :project,
      :worktree_path,
      :provider,
      :access,
      :hostname,
      :url,
      :local_port,
      :command_source,
      :origin_port,
      :tunnel_port,
      :tunnel_id,
      :dns_record_id,
      :access_app_id,
      :access_policy_id,
      :tailscale_mode,
      :tailscale_https_port,
      :tailscale_remote_port,
      :started_at,
      :expires_at
    ]
  end

  defstruct previews: %{},
            next_id: 1,
            config: %{},
            clients: %{cloudflare: CloudflareClient, tailscale: TailscaleClient},
            path: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def enabled?(server \\ __MODULE__), do: GenServer.call(server, :enabled?)

  def start_preview(server \\ __MODULE__, job, provider \\ nil) do
    GenServer.call(server, {:start_preview, job, provider}, 60_000)
  end

  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  def stop_preview(server \\ __MODULE__, preview_id) do
    GenServer.call(server, {:stop_preview, preview_id}, 30_000)
  end

  @impl true
  def init(opts) do
    config = opts[:config] || Application.get_env(:claude_notify, :preview, %{})
    path = opts[:path] || default_path()

    clients =
      opts[:clients] ||
        %{
          cloudflare: opts[:client] || CloudflareClient,
          tailscale: TailscaleClient
        }

    state = %__MODULE__{
      previews: load(path),
      config: config,
      clients: clients,
      path: path
    }

    {:ok, state, {:continue, :cleanup_stale}}
  end

  @impl true
  def handle_continue(:cleanup_stale, state) do
    if configured?(state) do
      Enum.each(state.previews, fn {_id, preview} ->
        cleanup_provider(preview, state)
      end)

      state = %{state | previews: %{}}
      persist(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:enabled?, _from, state), do: {:reply, configured?(state), state}

  def handle_call(:list, _from, state) do
    previews = state.previews |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, previews, state}
  end

  def handle_call({:start_preview, job, requested_provider}, _from, state) do
    case existing_for_job(state, job.id) do
      nil ->
        case launch_preview(job, requested_provider, state) do
          {:ok, preview} ->
            Process.send_after(
              self(),
              {:expire, preview.id},
              max((preview.expires_at - System.system_time(:second)) * 1_000, 0)
            )

            new_state = %{
              state
              | previews: Map.put(state.previews, preview.id, preview),
                next_id: preview.id + 1
            }

            persist(new_state)
            refresh_dashboard()
            {:reply, {:ok, public_preview(preview)}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      preview ->
        {:reply, {:ok, public_preview(preview)}, state}
    end
  end

  def handle_call({:stop_preview, preview_id}, _from, state) do
    case Map.get(state.previews, preview_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      preview ->
        cleanup_preview(preview, state)
        new_state = %{state | previews: Map.delete(state.previews, preview_id)}
        persist(new_state)
        refresh_dashboard()
        {:reply, {:ok, public_preview(preview)}, new_state}
    end
  end

  @impl true
  def handle_info({:expire, preview_id}, state) do
    case Map.get(state.previews, preview_id) do
      nil ->
        {:noreply, state}

      preview ->
        cleanup_preview(preview, state)
        new_state = %{state | previews: Map.delete(state.previews, preview_id)}
        persist(new_state)
        refresh_dashboard()
        {:noreply, new_state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) do
    case find_by_port(state.previews, port) do
      nil ->
        {:noreply, state}

      preview ->
        Logger.warning(
          "PreviewManager: preview #{preview.id} process exited with status #{status}; cleaning up"
        )

        cleanup_preview(preview, state, port)
        new_state = %{state | previews: Map.delete(state.previews, preview.id)}
        persist(new_state)
        refresh_dashboard()
        {:noreply, new_state}
    end
  end

  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.previews, fn {_id, preview} -> cleanup_preview(preview, state) end)
    :ok
  end

  defp launch_preview(job, requested_provider, state) do
    with :ok <- validate_job(job),
         {:ok, provider, client, provider_config} <-
           resolve_provider(state, requested_provider),
         {:ok, local_port} <- available_port(state.config),
         {:ok, command} <- PreviewCommand.resolve(job.worktree_path, local_port),
         {:ok, origin_port} <- open_origin(command, job.worktree_path),
         :ok <- wait_for_origin(origin_port, local_port, @origin_attempts) do
      provision_preview(
        job,
        state,
        provider,
        client,
        provider_config,
        local_port,
        command,
        origin_port
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp provision_preview(
         job,
         state,
         provider,
         client,
         provider_config,
         local_port,
         command,
         origin_port
       ) do
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    name = "claude-notify-preview-#{job.id}-#{suffix}"
    local_url = "http://127.0.0.1:#{local_port}"

    with {:ok, provider_config} <- allocate_provider_port(provider, provider_config, state),
         hostname <- preview_hostname(provider, provider_config, job.id, suffix),
         {:ok, resources} <- client.provision(provider_config, hostname, local_url, name) do
      finish_provision(
        job,
        state,
        provider,
        client,
        provider_config,
        local_port,
        command,
        origin_port,
        hostname,
        resources
      )
    else
      {:error, reason} ->
        close_port(origin_port)
        {:error, reason}
    end
  end

  defp finish_provision(
         job,
         state,
         provider,
         client,
         provider_config,
         local_port,
         command,
         origin_port,
         requested_hostname,
         resources
       ) do
    case open_connector(provider, provider_config, resources) do
      {:ok, connector_port} ->
        now = System.system_time(:second)
        ttl = state.config[:ttl_seconds] || 7_200
        hostname = Map.get(resources, :hostname) || requested_hostname
        url = Map.get(resources, :url) || "https://#{hostname}"

        {:ok,
         struct!(Preview, %{
           id: state.next_id,
           job_id: job.id,
           project: job.project,
           worktree_path: job.worktree_path,
           provider: provider,
           access: access_label(provider, resources),
           hostname: hostname,
           url: url,
           local_port: local_port,
           command_source: command.source,
           origin_port: origin_port,
           tunnel_port: connector_port,
           tunnel_id: Map.get(resources, :tunnel_id),
           dns_record_id: Map.get(resources, :dns_record_id),
           access_app_id: Map.get(resources, :access_app_id),
           access_policy_id: Map.get(resources, :access_policy_id),
           tailscale_mode: Map.get(resources, :tailscale_mode),
           tailscale_https_port: Map.get(resources, :tailscale_https_port),
           tailscale_remote_port: Map.get(resources, :tailscale_remote_port),
           started_at: now,
           expires_at: now + ttl
         })}

      {:error, reason} ->
        close_port(origin_port)
        client.cleanup(provider_config, resources)
        {:error, reason}
    end
  end

  defp open_connector(:cloudflare, config, resources) do
    with {:ok, cloudflared} <- cloudflared_executable(config),
         token when is_binary(token) <- Map.get(resources, :tunnel_token) do
      open_tunnel(cloudflared, token)
    else
      nil -> {:error, :missing_tunnel_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_connector(:tailscale, _config, resources) do
    {:ok, Map.get(resources, :connector_port)}
  end

  defp preview_hostname(:cloudflare, config, job_id, suffix) do
    "preview-#{job_id}-#{suffix}.#{config.domain}"
  end

  defp preview_hostname(:tailscale, _config, _job_id, _suffix), do: nil

  defp access_label(:cloudflare, _resources), do: :otp
  defp access_label(:tailscale, %{tailscale_mode: :funnel}), do: :public
  defp access_label(:tailscale, _resources), do: :tailnet

  defp allocate_provider_port(:cloudflare, config, _state), do: {:ok, config}

  defp allocate_provider_port(:tailscale, config, state) do
    previews = Map.values(state.previews)
    used_https = previews |> Enum.map(& &1.tailscale_https_port) |> MapSet.new()
    https_port = Enum.find(tailscale_ports(config), &(not MapSet.member?(used_https, &1)))

    if is_nil(https_port) do
      {:error, :tailscale_port_unavailable}
    else
      allocate_remote_port(config, previews, https_port)
    end
  end

  defp allocate_remote_port(config, previews, https_port) do
    if is_binary(config[:ssh_host]) and String.trim(config[:ssh_host]) != "" do
      used_remote = previews |> Enum.map(& &1.tailscale_remote_port) |> MapSet.new()
      first = config[:remote_port_start] || 45_300
      last = config[:remote_port_end] || 45_399

      case Enum.find(first..last, &(not MapSet.member?(used_remote, &1))) do
        nil ->
          {:error, :tailscale_remote_port_unavailable}

        remote_port ->
          {:ok, Map.merge(config, %{https_port: https_port, remote_port: remote_port})}
      end
    else
      {:ok, Map.put(config, :https_port, https_port)}
    end
  end

  defp tailscale_ports(config) do
    if tailscale_mode(config) == :funnel do
      [443, 8443, 10_000]
    else
      (config[:https_port_start] || 44_300)..(config[:https_port_end] || 44_399)
    end
  end

  defp tailscale_mode(config) do
    if config[:mode] in [:funnel, "funnel"], do: :funnel, else: :serve
  end

  defp validate_job(%{worktree_path: path}) when is_binary(path) do
    if File.dir?(path), do: :ok, else: {:error, :worktree_missing}
  end

  defp validate_job(_job), do: {:error, :worktree_missing}

  defp configured?(state) do
    Enum.any?([:cloudflare, :tailscale], fn provider ->
      provider_config = provider_config(state.config, provider)
      client = Map.fetch!(state.clients, provider)
      client.configured?(provider_config)
    end)
  end

  defp resolve_provider(state, requested_provider) do
    with {:ok, requested} <- normalize_provider(requested_provider),
         provider when provider in [:cloudflare, :tailscale] <- choose_provider(state, requested),
         client <- Map.fetch!(state.clients, provider),
         config <- provider_config(state.config, provider),
         true <- client.configured?(config) do
      {:ok, provider, client, config}
    else
      false -> {:error, {:provider_not_configured, normalize_provider_name(requested_provider)}}
      nil -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_provider(nil), do: {:ok, :auto}
  defp normalize_provider(:auto), do: {:ok, :auto}
  defp normalize_provider("auto"), do: {:ok, :auto}
  defp normalize_provider(:cloudflare), do: {:ok, :cloudflare}
  defp normalize_provider("cloudflare"), do: {:ok, :cloudflare}
  defp normalize_provider(:tailscale), do: {:ok, :tailscale}
  defp normalize_provider("tailscale"), do: {:ok, :tailscale}
  defp normalize_provider(_), do: {:error, :unknown_preview_provider}

  defp normalize_provider_name(nil), do: :auto
  defp normalize_provider_name(provider), do: provider

  defp choose_provider(state, :auto) do
    preferred =
      case normalize_provider(state.config[:default_provider]) do
        {:ok, provider} -> provider
        _ -> :auto
      end

    candidates = if preferred == :auto, do: [:cloudflare, :tailscale], else: [preferred]

    Enum.find(candidates, fn provider ->
      Map.fetch!(state.clients, provider).configured?(provider_config(state.config, provider))
    end)
  end

  defp choose_provider(_state, provider), do: provider

  defp provider_config(config, provider) do
    # Old flat configs are accepted for tests and upgrades from the initial
    # Cloudflare-only preview implementation.
    if provider == :cloudflare and not is_map(config[:cloudflare]) do
      config
    else
      config
      |> Map.get(provider, %{})
      |> Map.put_new(:ttl_seconds, config[:ttl_seconds])
    end
  end

  defp cloudflared_executable(config) do
    executable = config[:cloudflared_path] || "cloudflared"

    case System.find_executable(executable) do
      nil -> {:error, {:executable_not_found, executable}}
      path -> {:ok, path}
    end
  end

  defp available_port(config) do
    first = config[:port_start] || 41_000
    last = config[:port_end] || 41_999

    Enum.find_value(first..last, {:error, :no_preview_port_available}, fn port ->
      case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}]) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          {:ok, port}

        {:error, _} ->
          nil
      end
    end)
  end

  defp open_origin(command, worktree) do
    port =
      Port.open({:spawn_executable, command.executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: command.args,
        cd: worktree,
        env: port_env(command.env)
      ])

    {:ok, port}
  rescue
    error -> {:error, {:origin_start_failed, Exception.message(error)}}
  end

  defp wait_for_origin(_origin_port, _local_port, 0), do: {:error, :origin_not_ready}

  defp wait_for_origin(origin_port, local_port, attempts) do
    cond do
      is_nil(Port.info(origin_port)) ->
        {:error, :origin_exited}

      tcp_ready?(local_port) ->
        :ok

      true ->
        Process.sleep(@origin_retry_ms)
        wait_for_origin(origin_port, local_port, attempts - 1)
    end
  end

  defp tcp_ready?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp open_tunnel(executable, token) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["tunnel", "--no-autoupdate", "run"],
        env: port_env([{"TUNNEL_TOKEN", token}])
      ])

    Process.sleep(500)

    if Port.info(port) do
      {:ok, port}
    else
      {:error, :tunnel_exited}
    end
  rescue
    error -> {:error, {:tunnel_start_failed, Exception.message(error)}}
  end

  defp existing_for_job(state, job_id) do
    Enum.find_value(state.previews, fn {_id, preview} ->
      if preview.job_id == job_id, do: preview
    end)
  end

  defp find_by_port(previews, port) do
    Enum.find_value(previews, fn {_id, preview} ->
      if preview.origin_port == port or preview.tunnel_port == port, do: preview
    end)
  end

  defp cleanup_preview(preview, state, already_closed \\ nil) do
    stop_ports(preview, already_closed)
    cleanup_provider(preview, state)
  end

  defp cleanup_provider(preview, state) do
    provider = Map.get(preview, :provider) || :cloudflare
    client = Map.get(state.clients, provider)
    config = provider_config(state.config, provider)

    if client && client.configured?(config) do
      client.cleanup(config, preview)
    else
      Logger.warning(
        "PreviewManager: provider #{inspect(provider)} is unavailable during cleanup"
      )
    end

    :ok
  end

  defp stop_ports(preview, already_closed) do
    for port <- [preview.origin_port, preview.tunnel_port], port != already_closed do
      close_port(port)
    end
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp port_env(env) do
    Enum.map(env, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp refresh_dashboard do
    if Process.whereis(ClaudeNotify.Dashboard), do: ClaudeNotify.Dashboard.refresh()
    :ok
  end

  defp public_preview(preview) do
    Map.drop(preview, [:origin_port, :tunnel_port])
  end

  defp persist(%{path: nil}), do: :ok

  defp persist(state) do
    previews =
      Map.new(state.previews, fn {id, preview} ->
        {id, public_preview(preview)}
      end)

    data = :erlang.term_to_binary(%{previews: previews})
    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, state.path)
    :ok
  end

  defp load(nil), do: %{}

  defp load(path) do
    with true <- File.exists?(path),
         {:ok, binary} <- File.read(path),
         %{previews: previews} <- :erlang.binary_to_term(binary, [:safe]) do
      previews
    else
      _ -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp default_path do
    Application.get_env(
      :claude_notify,
      :preview_store_path,
      Path.join([System.user_home!(), ".claude_notify", "preview_store.dat"])
    )
  end
end
