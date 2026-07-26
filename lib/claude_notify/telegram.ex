defmodule ClaudeNotify.Telegram do
  require Logger

  @max_retries 3
  @telegram_text_limit 4096

  @doc """
  Sends a message with automatic retry on 429 (rate limit) responses.

  When `text` exceeds Telegram's 4096-char limit, it is split into chunks on
  paragraph/newline boundaries and each chunk is sent as plain text (no
  MarkdownV2). Splitting markdown mid-entity makes Telegram reject the message
  with `can't parse entities`, so chunked sends drop formatting deliberately.

  Returns the result of the first chunk send. Subsequent chunks are sent
  fire-and-forget; their failures are logged but not propagated.
  """
  def send_message_with_retry(text, retries \\ @max_retries) when is_binary(text) do
    case chunk(text) do
      [single] ->
        send_with_429_retry(single, retries, parse_mode: "MarkdownV2")

      [first | rest] ->
        result = send_with_429_retry(first, retries, parse_mode: nil)

        Enum.each(rest, fn part ->
          send_with_429_retry(part, retries, parse_mode: nil)
        end)

        result
    end
  end

  @doc """
  Sends a message with buttons and automatic retry on 429 responses.

  If `text` exceeds the limit, the leading chunks are sent as plain-text
  messages and the buttons attach to the final chunk so they remain reachable.
  """
  def send_with_buttons_retry(text, buttons, retries \\ @max_retries) when is_binary(text) do
    case chunk(text) do
      [single] ->
        retry_429(fn -> send_with_buttons(single, buttons) end, retries)

      chunks ->
        {leading, [last]} = Enum.split(chunks, length(chunks) - 1)

        Enum.each(leading, fn part ->
          send_with_429_retry(part, retries, parse_mode: nil)
        end)

        retry_429(fn -> send_with_buttons(last, buttons, parse_mode: nil) end, retries)
    end
  end

  @doc """
  Edits an existing message's text. Returns {:ok, response} or {:error, reason}.

  Accepts `parse_mode` opt: defaults to `"MarkdownV2"`. Pass `parse_mode: nil`
  to send as plain text.
  """
  def edit_message_text(message_id, text, opts \\ []) do
    parse_mode = Keyword.get(opts, :parse_mode, "MarkdownV2")

    body =
      %{
        chat_id: chat_id(),
        message_id: message_id,
        text: text
      }
      |> maybe_put_parse_mode(parse_mode)

    api_post("editMessageText", body)
  end

  @doc """
  Edits an existing message's text and inline keyboard together, in one
  editMessageText call - mirrors `send_with_buttons/2`'s `buttons` shape
  (a list of `[label, callback_data]` pairs, laid out in one row). Pass
  `[]` to clear a message's buttons (e.g. once its actions are no longer
  valid) rather than leaving stale ones in place.
  """
  def edit_message_text_with_buttons(message_id, text, buttons) do
    body = %{
      chat_id: chat_id(),
      message_id: message_id,
      text: text,
      parse_mode: "MarkdownV2",
      reply_markup: %{inline_keyboard: inline_keyboard(buttons)}
    }

    api_post("editMessageText", body)
  end

  @doc """
  Edits only an existing message's inline keyboard, leaving its text
  untouched - the companion to `edit_message_text_with_buttons/3` for
  callers that need to swap a message's buttons (e.g. Watch -> Unwatch)
  without needing to know or resend its current text.
  """
  def edit_message_reply_markup(message_id, buttons) do
    body = %{
      chat_id: chat_id(),
      message_id: message_id,
      reply_markup: %{inline_keyboard: inline_keyboard(buttons)}
    }

    api_post("editMessageReplyMarkup", body)
  end

  defp inline_keyboard([]), do: []

  defp inline_keyboard(buttons) do
    [Enum.map(buttons, fn [label, data] -> %{text: label, callback_data: data} end)]
  end

  @doc """
  Edits a message with automatic retry on 429 (rate limit) responses.
  """
  def edit_message_text_with_retry(message_id, text, retries \\ @max_retries) do
    retry_429(fn -> edit_message_text(message_id, text) end, retries, "edit")
  end

  defp retry_429(fun, retries, label \\ "send") do
    case fun.() do
      {:error, {429, body}} when retries > 0 ->
        retry_after = get_retry_after(body)

        Logger.warning(
          "Telegram rate limited (#{label}), retrying in #{retry_after}s (#{retries} left)"
        )

        Process.sleep(retry_after * 1_000)
        retry_429(fun, retries - 1, label)

      other ->
        other
    end
  end

  defp send_with_429_retry(text, retries, opts) do
    retry_429(fn -> send_message(text, opts) end, retries)
  end

  defp get_retry_after(%{"parameters" => %{"retry_after" => seconds}}) when is_integer(seconds),
    do: seconds

  defp get_retry_after(_), do: 1

  @doc """
  Sends a single message. Use `send_message_with_retry/1` for callers that
  need 429 backoff and automatic chunking of long text.

  Options:
    * `:parse_mode` — `"MarkdownV2"` (default), `"HTML"`, or `nil` for plain text.
  """
  def send_message(text, opts \\ []) do
    parse_mode = Keyword.get(opts, :parse_mode, "MarkdownV2")

    body =
      %{chat_id: chat_id(), text: text}
      |> maybe_put_parse_mode(parse_mode)

    api_post("sendMessage", body)
  end

  @doc """
  Sends a message with inline keyboard buttons.
  `buttons` is a list of `[label, callback_data]` pairs, e.g.:
    [["Yes", "sess:yes"], ["No", "sess:no"]]
  """
  def send_with_buttons(text, buttons, opts \\ []) do
    parse_mode = Keyword.get(opts, :parse_mode, "MarkdownV2")

    inline_keyboard =
      buttons
      |> Enum.map(fn [label, data] -> %{text: label, callback_data: data} end)
      |> then(fn row -> [row] end)

    body =
      %{
        chat_id: chat_id(),
        text: text,
        reply_markup: %{inline_keyboard: inline_keyboard}
      }
      |> maybe_put_parse_mode(parse_mode)

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
  Sets an emoji reaction on a message. Uses the setMessageReaction API.
  `emoji` should be a single emoji string like "👀", "🔥", "👍".
  """
  def set_message_reaction(message_id, emoji) do
    body = %{
      chat_id: chat_id(),
      message_id: message_id,
      reaction: [%{type: "emoji", emoji: emoji}],
      is_big: false
    }

    api_post("setMessageReaction", body)
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
  Sends a chat action like `"typing"`, `"upload_photo"`, `"upload_document"`.
  Telegram displays this for ~5 seconds or until the next message is sent.
  """
  def send_chat_action(chat_id, action) when is_binary(action) do
    api_post("sendChatAction", %{chat_id: chat_id, action: action})
  end

  @doc """
  Registers the bot's command list. Telegram's clients use this for the
  command autocomplete menu. `commands` is a list of `%{command: "name",
  description: "desc"}` maps.

  `scope` defaults to all private chats; pass `nil` for default scope.
  """
  def set_my_commands(commands, scope \\ %{type: "all_private_chats"}) do
    body =
      %{commands: commands}
      |> then(fn b -> if scope, do: Map.put(b, :scope, scope), else: b end)

    api_post("setMyCommands", body)
  end

  @doc """
  Looks up file metadata by Telegram file_id. Returns `{:ok, %{"file_path" => ...}}`
  on success. The path is a relative key into Telegram's CDN.
  """
  def get_file(file_id) when is_binary(file_id) do
    case api_post("getFile", %{file_id: file_id}) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, _} -> {:error, :no_result}
      error -> error
    end
  end

  @doc """
  Downloads a file from Telegram's CDN given a `file_path` (from `get_file/1`).
  Returns `{:ok, binary}` or `{:error, reason}`. Telegram caps bot downloads at 20MB.
  """
  def download_file(file_path) when is_binary(file_path) do
    url = "#{base_url()}/file/bot#{token()}/#{file_path}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Public API post for modules that need to send custom Telegram requests.
  """
  def api_post_public(method, body), do: api_post(method, body)

  @doc """
  Splits `text` into a list of chunks each ≤ `limit` characters.

  Strategy: greedy paragraph (`\\n\\n`) packing first, then line (`\\n`) packing
  for any oversized paragraph, finally a hard grapheme split for lines that
  still exceed `limit`. The split is grapheme-aware so multi-byte characters
  (emoji, accents) are never cut in half.
  """
  def chunk(text, limit \\ @telegram_text_limit) when is_binary(text) and limit > 0 do
    if String.length(text) <= limit do
      [text]
    else
      text
      |> String.split("\n\n", trim: false)
      |> repack_with("\n\n", limit)
      |> Enum.flat_map(&maybe_split_paragraph(&1, limit))
    end
  end

  defp maybe_split_paragraph(part, limit) do
    if String.length(part) <= limit do
      [part]
    else
      part
      |> String.split("\n", trim: false)
      |> repack_with("\n", limit)
      |> Enum.flat_map(&maybe_split_line(&1, limit))
    end
  end

  defp maybe_split_line(part, limit) do
    if String.length(part) <= limit do
      [part]
    else
      part
      |> String.graphemes()
      |> Enum.chunk_every(limit)
      |> Enum.map(&Enum.join/1)
    end
  end

  # Greedily packs consecutive parts back together with `sep` while length ≤ limit.
  defp repack_with(parts, sep, limit) do
    parts
    |> Enum.reduce([], fn part, acc ->
      case acc do
        [] ->
          [part]

        [last | rest] ->
          candidate = last <> sep <> part

          if String.length(candidate) <= limit do
            [candidate | rest]
          else
            [part, last | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_put_parse_mode(body, nil), do: body
  defp maybe_put_parse_mode(body, mode), do: Map.put(body, :parse_mode, mode)

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
