defmodule ClaudeNotify.EventAuth do
  @moduledoc """
  Verifies signed webhook requests for `/api/events`.
  """

  alias Plug.Conn
  alias ClaudeNotify.ReplayCache

  @signature_header "x-claude-notify-signature"
  @timestamp_header "x-claude-notify-timestamp"

  def verify(conn) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, raw_body} <- fetch_raw_body(conn),
         {:ok, timestamp} <- parse_timestamp(Conn.get_req_header(conn, @timestamp_header)),
         :ok <- validate_timestamp_freshness(timestamp),
         {:ok, signature} <- parse_signature(Conn.get_req_header(conn, @signature_header)),
         :ok <- validate_signature(secret, timestamp, raw_body, signature),
         :ok <- validate_replay(timestamp, signature) do
      :ok
    end
  end

  defp fetch_secret do
    case Application.get_env(:claude_notify, :webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :webhook_secret_not_configured}
    end
  end

  defp fetch_raw_body(%Conn{private: %{raw_body: raw_body}})
       when is_binary(raw_body) and raw_body != "" do
    {:ok, raw_body}
  end

  defp fetch_raw_body(_conn), do: {:error, :missing_raw_body}

  defp parse_timestamp([value]) do
    case Integer.parse(value) do
      {timestamp, ""} when timestamp > 0 -> {:ok, timestamp}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp([]), do: {:error, :missing_timestamp}
  defp parse_timestamp(_), do: {:error, :invalid_timestamp}

  defp parse_signature([<<"sha256=", digest::binary>>]), do: validate_digest(digest)
  defp parse_signature([digest]), do: validate_digest(digest)
  defp parse_signature([]), do: {:error, :missing_signature}
  defp parse_signature(_), do: {:error, :invalid_signature_format}

  defp validate_digest(digest) do
    normalized = String.downcase(String.trim(digest))

    if String.match?(normalized, ~r/^[0-9a-f]{64}$/) do
      {:ok, normalized}
    else
      {:error, :invalid_signature_format}
    end
  end

  defp validate_timestamp_freshness(timestamp) do
    now = System.system_time(:second)
    skew = Application.get_env(:claude_notify, :webhook_max_skew_seconds, 300)

    if abs(now - timestamp) <= skew do
      :ok
    else
      {:error, :timestamp_out_of_range}
    end
  end

  defp validate_signature(secret, timestamp, raw_body, signature) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp validate_replay(timestamp, signature) do
    skew = Application.get_env(:claude_notify, :webhook_max_skew_seconds, 300)
    ttl = max(skew * 2, 60)
    key = "#{timestamp}:#{signature}"

    case ReplayCache.check_and_put(key, ttl) do
      :ok -> :ok
      :replay -> {:error, :replay}
    end
  end
end
