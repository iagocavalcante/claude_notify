defmodule ClaudeNotify.Telegram do
  require Logger

  @max_retries 3

  @doc """
  Sends a message with automatic retry on 429 (rate limit) responses.
  """
  def send_message_with_retry(text, retries \\ @max_retries) do
    case send_message(text) do
      {:error, {429, body}} when retries > 0 ->
        retry_after = get_retry_after(body)
        Logger.warning("Telegram rate limited, retrying in #{retry_after}s (#{retries} left)")
        Process.sleep(retry_after * 1_000)
        send_message_with_retry(text, retries - 1)

      other ->
        other
    end
  end

  @doc """
  Sends a message with buttons and automatic retry on 429 responses.
  """
  def send_with_buttons_retry(text, buttons, retries \\ @max_retries) do
    case send_with_buttons(text, buttons) do
      {:error, {429, body}} when retries > 0 ->
        retry_after = get_retry_after(body)
        Logger.warning("Telegram rate limited, retrying in #{retry_after}s (#{retries} left)")
        Process.sleep(retry_after * 1_000)
        send_with_buttons_retry(text, buttons, retries - 1)

      other ->
        other
    end
  end

  defp get_retry_after(%{"parameters" => %{"retry_after" => seconds}}) when is_integer(seconds),
    do: seconds

  defp get_retry_after(_), do: 1

  def send_message(text) do
    body = %{
      chat_id: chat_id(),
      text: text,
      parse_mode: "MarkdownV2"
    }

    api_post("sendMessage", body)
  end

  @doc """
  Sends a message with inline keyboard buttons.
  `buttons` is a list of `[label, callback_data]` pairs, e.g.:
    [["Yes", "sess:yes"], ["No", "sess:no"]]
  """
  def send_with_buttons(text, buttons) do
    inline_keyboard =
      buttons
      |> Enum.map(fn [label, data] -> %{text: label, callback_data: data} end)
      |> then(fn row -> [row] end)

    body = %{
      chat_id: chat_id(),
      text: text,
      parse_mode: "MarkdownV2",
      reply_markup: %{inline_keyboard: inline_keyboard}
    }

    api_post("sendMessage", body)
  end

  @doc """
  Acknowledges a callback query to dismiss the loading indicator on the button.
  """
  def answer_callback_query(callback_query_id, text \\ nil) do
    body =
      %{callback_query_id: callback_query_id}
      |> then(fn b -> if text, do: Map.put(b, :text, text), else: b end)

    api_post("answerCallbackQuery", body)
  end

  @doc """
  Polls for updates using long polling. Returns the list of updates.
  """
  def get_updates(offset, timeout \\ 30) do
    params = %{offset: offset, timeout: timeout, allowed_updates: ["callback_query", "message"]}

    # Req receive_timeout must exceed Telegram's long poll timeout
    case api_post("getUpdates", params, receive_timeout: :timer.seconds(timeout + 5)) do
      {:ok, %{"result" => results}} -> {:ok, results}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Public API post for modules that need to send custom Telegram requests.
  """
  def api_post_public(method, body), do: api_post(method, body)

  defp api_post(method, body, req_opts \\ []) do
    url = "#{base_url()}/bot#{token()}/#{method}"

    case Req.post(url, [json: body] ++ req_opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning(
          "Telegram API error: #{method} status=#{status} body=#{inspect(resp_body)}"
        )

        {:error, {status, resp_body}}

      {:error, reason} ->
        Logger.error("Telegram request failed: #{method} #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp token, do: Application.get_env(:claude_notify, :telegram_bot_token)
  defp chat_id, do: Application.get_env(:claude_notify, :telegram_chat_id)
  defp base_url, do: Application.get_env(:claude_notify, :telegram_base_url)
end
