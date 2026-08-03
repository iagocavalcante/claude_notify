defmodule ClaudeNotify.TailscaleClientTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.TailscaleClient

  @moduletag :tmp_dir

  test "creates and removes a private Serve route", %{tmp_dir: dir} do
    executable = fake_tailscale(dir)

    config = %{
      tailscale_path: executable,
      mode: :serve,
      https_port: 44_301
    }

    assert TailscaleClient.configured?(config)

    assert {:ok, resources} =
             TailscaleClient.provision(
               config,
               nil,
               "http://127.0.0.1:41001",
               "preview"
             )

    assert resources.url == "https://devbox.example.ts.net:44301"
    assert resources.hostname == "devbox.example.ts.net"
    assert resources.tailscale_mode == :serve
    assert resources.tailscale_https_port == 44_301

    assert :ok = TailscaleClient.cleanup(config, resources)

    commands = File.read!(executable <> ".log")
    assert commands =~ "serve --bg --yes --https=44301 http://127.0.0.1:41001"
    assert commands =~ "serve --yes --https=44301 off"
  end

  test "Funnel produces a public URL on its selected port", %{tmp_dir: dir} do
    executable = fake_tailscale(dir)
    config = %{tailscale_path: executable, mode: "funnel", https_port: 8443}

    assert {:ok, resources} =
             TailscaleClient.provision(config, nil, "http://127.0.0.1:41002", "preview")

    assert resources.url == "https://devbox.example.ts.net:8443"
    assert resources.tailscale_mode == :funnel
  end

  test "uses an SSH reverse tunnel when a relay host is configured", %{tmp_dir: dir} do
    ssh = fake_ssh(dir)

    config = %{
      ssh_host: "ssh-tron",
      ssh_path: ssh,
      tailscale_path: "tailscale",
      mode: :serve,
      https_port: 44_302,
      remote_port: 45_302
    }

    assert TailscaleClient.configured?(config)

    assert {:ok, resources} =
             TailscaleClient.provision(
               config,
               nil,
               "http://127.0.0.1:41003",
               "preview"
             )

    assert resources.url == "https://relay.example.ts.net:44302"
    assert resources.tailscale_remote_port == 45_302
    assert is_port(resources.connector_port)

    commands = File.read!(ssh <> ".log")
    assert commands =~ "-R 127.0.0.1:45302:127.0.0.1:41003 ssh-tron"
    assert commands =~ "ssh-tron 'tailscale' 'serve' '--bg' '--yes' '--https=44302'"

    Port.close(resources.connector_port)
    assert :ok = TailscaleClient.cleanup(config, resources)
  end

  defp fake_tailscale(dir) do
    path = Path.join(dir, "tailscale-fixture")

    File.write!(
      path,
      """
      #!/usr/bin/env bash
      if [ "$1" = "status" ]; then
        printf '%s' '{"BackendState":"Running","Self":{"DNSName":"devbox.example.ts.net."}}'
        exit 0
      fi
      printf '%s\n' "$*" >> "$0.log"
      """
    )

    File.chmod!(path, 0o755)
    path
  end

  defp fake_ssh(dir) do
    path = Path.join(dir, "ssh-fixture")

    File.write!(
      path,
      """
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$0.log"
      if [ "$1" = "-N" ]; then
        exec sleep 30
      fi
      case "$*" in
        *"'status' '--json'"*)
          printf '%s' '{"BackendState":"Running","Self":{"DNSName":"relay.example.ts.net."}}'
          ;;
      esac
      """
    )

    File.chmod!(path, 0o755)
    path
  end
end
