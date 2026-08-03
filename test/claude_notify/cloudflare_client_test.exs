defmodule ClaudeNotify.CloudflareClientTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.CloudflareClient

  test "requires every credential, a domain, and at least one allowed email" do
    complete = %{
      api_token: "token",
      account_id: "account",
      zone_id: "zone",
      domain: "example.com",
      allowed_emails: ["tester@example.com"]
    }

    assert CloudflareClient.configured?(complete)
    refute CloudflareClient.configured?(%{complete | api_token: nil})
    refute CloudflareClient.configured?(%{complete | allowed_emails: []})
  end

  test "refuses provisioning before making requests when configuration is incomplete" do
    config = %{api_token: nil, account_id: nil, zone_id: nil, domain: nil, allowed_emails: []}

    assert CloudflareClient.provision(config, "preview.example.com", "http://127.0.0.1:1", "test") ==
             {:error, :not_configured}
  end

  test "provisions OTP, tunnel, DNS, Access app, and email policy without leaking the token" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = if body == "", do: nil, else: Jason.decode!(body)
      send(test_pid, {:cloudflare_request, conn.method, conn.request_path, decoded})

      result =
        case {conn.method, conn.request_path} do
          {"GET", "/accounts/account/access/identity_providers"} ->
            [%{"id" => "otp-id", "type" => "onetimepin"}]

          {"POST", "/accounts/account/cfd_tunnel"} ->
            %{"id" => "tunnel-id", "token" => "tunnel-secret"}

          {"PUT", "/accounts/account/cfd_tunnel/tunnel-id/configurations"} ->
            %{}

          {"POST", "/zones/zone/dns_records"} ->
            %{"id" => "dns-id"}

          {"POST", "/accounts/account/access/apps"} ->
            %{"id" => "app-id"}

          {"POST", "/accounts/account/access/apps/app-id/policies"} ->
            %{"id" => "policy-id"}

          {"DELETE", _path} ->
            %{"id" => "deleted"}
        end

      Req.Test.json(conn, %{"success" => true, "result" => result})
    end)

    config = %{
      api_token: "api-secret",
      account_id: "account",
      zone_id: "zone",
      domain: "example.com",
      allowed_emails: ["tester@example.com"],
      base_url: "https://api.cloudflare.test",
      req_options: [plug: {Req.Test, __MODULE__}]
    }

    assert {:ok, resources} =
             CloudflareClient.provision(
               config,
               "preview-1.example.com",
               "http://127.0.0.1:41000",
               "preview-1"
             )

    assert resources == %{
             tunnel_id: "tunnel-id",
             tunnel_token: "tunnel-secret",
             dns_record_id: "dns-id",
             access_app_id: "app-id",
             access_policy_id: "policy-id"
           }

    requests = collect_requests(6)
    refute inspect(requests) =~ "api-secret"
    refute inspect(requests) =~ "tunnel-secret"

    assert Enum.any?(requests, fn
             {:cloudflare_request, "POST", "/accounts/account/access/apps", body} ->
               body["allowed_idps"] == ["otp-id"] and body["auto_redirect_to_identity"]

             _ ->
               false
           end)

    assert Enum.any?(requests, fn
             {:cloudflare_request, "POST", path, body} ->
               path == "/accounts/account/access/apps/app-id/policies" and
                 body["include"] == [%{"email" => %{"email" => "tester@example.com"}}]

             _ ->
               false
           end)

    assert :ok = CloudflareClient.cleanup(config, resources)

    cleanup_requests = collect_requests(4)

    assert Enum.map(cleanup_requests, fn {_, method, path, _} -> {method, path} end) == [
             {"DELETE", "/accounts/account/access/apps/app-id"},
             {"DELETE", "/zones/zone/dns_records/dns-id"},
             {"DELETE", "/accounts/account/cfd_tunnel/tunnel-id/connections"},
             {"DELETE", "/accounts/account/cfd_tunnel/tunnel-id"}
           ]
  end

  defp collect_requests(0), do: []

  defp collect_requests(count) do
    receive do
      {:cloudflare_request, _, _, _} = request ->
        [request | collect_requests(count - 1)]
    after
      1_000 -> flunk("expected #{count} more Cloudflare API requests")
    end
  end
end
