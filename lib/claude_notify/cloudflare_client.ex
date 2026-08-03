defmodule ClaudeNotify.CloudflareClient do
  @moduledoc """
  Minimal Cloudflare API client for short-lived, Access-protected previews.

  A preview owns a remotely-managed Tunnel, a proxied CNAME, a self-hosted
  Access application, and an application-scoped allow policy. The shared OTP
  identity provider is discovered or created once and is never removed when a
  preview expires.
  """

  require Logger

  @base_url "https://api.cloudflare.com/client/v4"

  def configured?(config) do
    required = [:api_token, :account_id, :zone_id, :domain]

    Enum.all?(required, &present?(config[&1])) and
      is_list(config[:allowed_emails]) and config[:allowed_emails] != []
  end

  def provision(config, hostname, local_url, name) do
    with :ok <- validate_config(config),
         {:ok, otp_idp_id} <- ensure_otp_idp(config),
         {:ok, tunnel} <- create_tunnel(config, name) do
      provision_tunnel(config, tunnel, otp_idp_id, hostname, local_url, name)
    end
  end

  def cleanup(config, resources) do
    delete_if_present(config, :access_app_id, resources, fn id ->
      request(config, :delete, "/accounts/#{config.account_id}/access/apps/#{id}")
    end)

    delete_if_present(config, :dns_record_id, resources, fn id ->
      request(config, :delete, "/zones/#{config.zone_id}/dns_records/#{id}")
    end)

    delete_if_present(config, :tunnel_id, resources, fn id ->
      request(
        config,
        :delete,
        "/accounts/#{config.account_id}/cfd_tunnel/#{id}/connections"
      )
    end)

    delete_if_present(config, :tunnel_id, resources, fn id ->
      request(config, :delete, "/accounts/#{config.account_id}/cfd_tunnel/#{id}")
    end)

    :ok
  end

  defp provision_tunnel(config, tunnel, otp_idp_id, hostname, local_url, name) do
    tunnel_id = tunnel["id"]
    resources = %{tunnel_id: tunnel_id}

    with :ok <- require_present(tunnel_id, :missing_tunnel_id),
         :ok <- require_present(tunnel["token"], :missing_tunnel_token),
         {:ok, _} <- configure_tunnel(config, tunnel_id, hostname, local_url),
         {:ok, dns} <- create_dns_record(config, tunnel_id, hostname) do
      provision_access(
        config,
        Map.put(resources, :dns_record_id, dns["id"]),
        tunnel["token"],
        otp_idp_id,
        hostname,
        name
      )
    else
      {:error, reason} -> rollback(config, resources, reason)
    end
  end

  defp provision_access(config, resources, tunnel_token, otp_idp_id, hostname, name) do
    case create_access_app(config, hostname, name, otp_idp_id) do
      {:ok, app} ->
        resources = Map.put(resources, :access_app_id, app["id"])

        case create_access_policy(config, app["id"], name) do
          {:ok, policy} ->
            {:ok,
             resources
             |> Map.put(:access_policy_id, policy["id"])
             |> Map.put(:tunnel_token, tunnel_token)}

          {:error, reason} ->
            rollback(config, resources, reason)
        end

      {:error, reason} ->
        rollback(config, resources, reason)
    end
  end

  defp validate_config(config) do
    if configured?(config), do: :ok, else: {:error, :not_configured}
  end

  defp ensure_otp_idp(config) do
    path = "/accounts/#{config.account_id}/access/identity_providers"

    with {:ok, providers} when is_list(providers) <- request(config, :get, path) do
      case Enum.find(providers, &(&1["type"] == "onetimepin")) do
        %{"id" => id} ->
          {:ok, id}

        nil ->
          case request(config, :post, path, %{
                 "name" => "Claude Notify preview OTP",
                 "type" => "onetimepin",
                 "config" => %{}
               }) do
            {:ok, %{"id" => id}} -> {:ok, id}
            {:ok, _} -> {:error, :missing_otp_identity_provider_id}
            error -> error
          end
      end
    end
  end

  defp create_tunnel(config, name) do
    request(config, :post, "/accounts/#{config.account_id}/cfd_tunnel", %{
      "name" => name,
      "config_src" => "cloudflare"
    })
  end

  defp configure_tunnel(config, tunnel_id, hostname, local_url) do
    request(
      config,
      :put,
      "/accounts/#{config.account_id}/cfd_tunnel/#{tunnel_id}/configurations",
      %{
        "config" => %{
          "ingress" => [
            %{
              "hostname" => hostname,
              "service" => local_url,
              "originRequest" => %{}
            },
            %{"service" => "http_status:404"}
          ]
        }
      }
    )
  end

  defp create_dns_record(config, tunnel_id, hostname) do
    request(config, :post, "/zones/#{config.zone_id}/dns_records", %{
      "type" => "CNAME",
      "proxied" => true,
      "ttl" => 1,
      "name" => hostname,
      "content" => "#{tunnel_id}.cfargotunnel.com",
      "comment" => "Ephemeral Claude Notify preview"
    })
  end

  defp create_access_app(config, hostname, name, otp_idp_id) do
    request(config, :post, "/accounts/#{config.account_id}/access/apps", %{
      "name" => name,
      "domain" => hostname,
      "type" => "self_hosted",
      "destinations" => [%{"type" => "public", "uri" => hostname}],
      "allowed_idps" => [otp_idp_id],
      "auto_redirect_to_identity" => true,
      "app_launcher_visible" => false,
      "session_duration" => config[:access_session_duration] || "1h"
    })
  end

  defp create_access_policy(config, app_id, name) do
    include =
      Enum.map(config.allowed_emails, fn email ->
        %{"email" => %{"email" => email}}
      end)

    request(
      config,
      :post,
      "/accounts/#{config.account_id}/access/apps/#{app_id}/policies",
      %{
        "name" => "#{name} allowed testers",
        "decision" => "allow",
        "precedence" => 1,
        "include" => include,
        "session_duration" => config[:access_session_duration] || "1h"
      }
    )
  end

  defp rollback(config, resources, reason) do
    cleanup(config, resources)
    {:error, reason}
  end

  defp delete_if_present(_config, key, resources, delete_fun) do
    case Map.get(resources, key) do
      id when is_binary(id) and id != "" ->
        case delete_fun.(id) do
          {:ok, _} ->
            :ok

          {:error, {:http_error, 404, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning("Cloudflare cleanup failed for #{key}: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    :ok
  end

  defp request(config, method, path, body \\ nil) do
    opts = [
      method: method,
      url: (config[:base_url] || @base_url) <> path,
      headers: [
        {"authorization", "Bearer #{config.api_token}"},
        {"content-type", "application/json"}
      ],
      retry: false,
      receive_timeout: config[:request_timeout] || 15_000
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)
    opts = Keyword.merge(opts, config[:req_options] || [])

    case Req.request(opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        if is_map(response) and response["success"] == false do
          {:error, {:cloudflare_error, sanitize_errors(response["errors"])}}
        else
          {:ok, if(is_map(response), do: response["result"], else: response)}
        end

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, sanitize_errors(response)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp sanitize_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      error when is_map(error) -> Map.take(error, ["code", "message"])
      other -> inspect(other)
    end)
  end

  defp sanitize_errors(%{"errors" => errors}), do: sanitize_errors(errors)
  defp sanitize_errors(other), do: inspect(other)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp require_present(value, error) do
    if present?(value), do: :ok, else: {:error, error}
  end
end
