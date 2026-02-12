defmodule ClaudeNotify.Telegram do
  require Logger

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
