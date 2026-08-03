defmodule ClaudeNotify.PreviewManagerTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.PreviewManager

  @moduletag :tmp_dir

  defmodule FakeCloudflare do
    def configured?(_config), do: true

    def provision(config, hostname, local_url, name) do
      send(config.test_pid, {:provision, hostname, local_url, name})

      {:ok,
       %{
         tunnel_id: "tunnel-id",
         tunnel_token: "secret-token",
         dns_record_id: "dns-id",
         access_app_id: "app-id",
         access_policy_id: "policy-id"
       }}
    end

    def cleanup(config, resources) do
      send(config.test_pid, {:cleanup, Map.get(resources, :tunnel_id)})
      :ok
    end
  end

  test "starts, lists, reuses, and removes an OTP-protected preview", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "index.html"), "preview")
    cloudflared = fake_cloudflared(dir)
    name = :"preview_manager_#{System.unique_integer([:positive])}"

    manager =
      start_supervised!(
        {PreviewManager,
         name: name,
         path: nil,
         client: FakeCloudflare,
         config: %{
           test_pid: self(),
           domain: "example.com",
           cloudflared_path: cloudflared,
           ttl_seconds: 60,
           port_start: 42_100,
           port_end: 42_199
         }}
      )

    job = %{id: 42, project: "website", worktree_path: dir}

    assert {:ok, preview} = PreviewManager.start_preview(manager, job)
    assert preview.job_id == 42
    assert preview.provider == :cloudflare
    assert preview.access == :otp
    assert preview.url =~ ~r|^https://preview-42-[a-f0-9]{6}\.example\.com$|
    assert preview.local_port in 42_100..42_199
    assert_receive {:provision, hostname, local_url, _name}
    assert hostname == preview.hostname
    assert local_url == "http://127.0.0.1:#{preview.local_port}"

    assert [listed] = PreviewManager.list(manager)
    assert listed.id == preview.id

    assert {:ok, same} = PreviewManager.start_preview(manager, job)
    assert same.id == preview.id
    refute_receive {:provision, _, _, _}, 50

    assert {:ok, stopped} = PreviewManager.stop_preview(manager, preview.id)
    assert stopped.id == preview.id
    assert_receive {:cleanup, "tunnel-id"}
    assert PreviewManager.list(manager) == []
  end

  defmodule FakeTailscale do
    def configured?(_config), do: true

    def provision(config, _hostname, local_url, _name) do
      send(config.test_pid, {:tailscale_provision, config.https_port, local_url})

      {:ok,
       %{
         hostname: "devbox.example.ts.net",
         url: "https://devbox.example.ts.net:#{config.https_port}",
         tailscale_mode: :serve,
         tailscale_https_port: config.https_port,
         tailscale_remote_port: config[:remote_port]
       }}
    end

    def cleanup(config, resources) do
      send(config.test_pid, {:tailscale_cleanup, resources.tailscale_https_port})
      :ok
    end
  end

  test "starts a tailnet-only preview through the selected provider", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "index.html"), "preview")
    name = :"preview_manager_#{System.unique_integer([:positive])}"

    manager =
      start_supervised!(
        {PreviewManager,
         name: name,
         path: nil,
         clients: %{cloudflare: FakeCloudflare, tailscale: FakeTailscale},
         config: %{
           default_provider: :tailscale,
           ttl_seconds: 60,
           port_start: 42_200,
           port_end: 42_299,
           cloudflare: %{test_pid: self()},
           tailscale: %{
             test_pid: self(),
             mode: :serve,
             https_port_start: 44_300,
             https_port_end: 44_399
           }
         }}
      )

    job = %{id: 43, project: "website", worktree_path: dir}
    assert {:ok, preview} = PreviewManager.start_preview(manager, job, :tailscale)
    assert preview.provider == :tailscale
    assert preview.access == :tailnet
    assert preview.url == "https://devbox.example.ts.net:44300"
    assert_receive {:tailscale_provision, 44_300, _local_url}

    assert {:ok, _} = PreviewManager.stop_preview(manager, preview.id)
    assert_receive {:tailscale_cleanup, 44_300}
  end

  test "rejects a job whose worktree no longer exists", %{tmp_dir: dir} do
    name = :"preview_manager_#{System.unique_integer([:positive])}"

    manager =
      start_supervised!(
        {PreviewManager,
         name: name,
         path: nil,
         client: FakeCloudflare,
         config: %{test_pid: self(), domain: "example.com"}}
      )

    job = %{id: 7, project: "gone", worktree_path: Path.join(dir, "missing")}
    assert PreviewManager.start_preview(manager, job) == {:error, :worktree_missing}
  end

  defp fake_cloudflared(dir) do
    path = Path.join(dir, "cloudflared-fixture")
    File.write!(path, "#!/usr/bin/env bash\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    path
  end
end
