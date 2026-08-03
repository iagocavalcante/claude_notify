defmodule ClaudeNotify.Telegram do
  require Logger

  @max_retries 3
  @telegram_text_limit 4096
  # Leave room for tags that must be closed and reopened at chunk boundaries.
  # OpenClaw uses the same conservative ceiling for Telegram HTML delivery.
  @telegram_html_limit 4000
  @telegram_html_tag ~r/<\/?[a-z][^>]*>/iu
  @telegram_html_token ~r/<\/?[a-z][^>]*>|&(?:#[0-9]+|#x[0-9a-f]+|[a-z][a-z0-9]+);|[^<&]+|./iu

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
  Sends Telegram HTML with safe chunking and automatic 429 retry.

  Formatting tags are closed at the end of a chunk and reopened in the next,
  so long agent responses keep both their complete content and formatting. If
  Telegram rejects a chunk's entities, that chunk is retried as readable plain
  text instead of being dropped.
  """
  def send_html_with_retry(text) when is_binary(text),
    do: send_html_with_retry(text, @max_retries, [])

  def send_html_with_retry(text, retries) when is_binary(text) and is_integer(retries),
    do: send_html_with_retry(text, retries, [])

  def send_html_with_retry(text, opts) when is_binary(text) and is_list(opts),
    do: send_html_with_retry(text, @max_retries, opts)

  def send_html_with_retry(text, retries, opts)
      when is_binary(text) and is_integer(retries) and is_list(opts) do
    text
    |> html_chunk(@telegram_html_limit)
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {part, index}, first_result ->
      chunk_opts =
        opts
        |> Keyword.put(:parse_mode, "HTML")
        |> maybe_drop_reply(index)

      result = send_html_chunk_with_fallback(part, retries, chunk_opts)

      case result do
        {:ok, _} ->
          {:cont, first_result || result}

        {:error, _} when is_nil(first_result) ->
          {:halt, result}

        {:error, reason} ->
          Logger.warning("Telegram HTML continuation failed: #{inspect(reason)}")
          {:halt, first_result}
      end
    end)
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
  Sends a message with multiple rows of inline buttons and 429 retry support.

  `rows` is a list of button rows; every button is `[label, callback_data]`.
  This is better suited to mobile pickers than `send_with_buttons_retry/3`,
  which deliberately renders all buttons in one compact row.
  """
  def send_with_button_rows_retry(text, rows, retries \\ @max_retries) when is_binary(text) do
    retry_429(fn -> send_with_button_rows(text, rows) end, retries)
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

  def edit_message_text_with_buttons_html(message_id, text, buttons) do
    body = %{
      chat_id: chat_id(),
      message_id: message_id,
      text: text,
      parse_mode: "HTML",
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

  @doc """
  Edits a message's text and inline keyboard together, with automatic
  retry on 429 responses - the buttons-carrying counterpart to
  `edit_message_text_with_retry/3`.
  """
  def edit_message_text_with_buttons_with_retry(
        message_id,
        text,
        buttons,
        retries \\ @max_retries
      ) do
    retry_429(
      fn -> edit_message_text_with_buttons(message_id, text, buttons) end,
      retries,
      "edit"
    )
  end

  def edit_message_text_with_buttons_html_retry(
        message_id,
        text,
        buttons,
        retries \\ @max_retries
      ) do
    retry_429(
      fn -> edit_message_text_with_buttons_html(message_id, text, buttons) end,
      retries,
      "edit"
    )
  end

  @doc """
  Edits only a message's inline keyboard, with automatic retry on 429
  responses - the retry-safe counterpart to `edit_message_reply_markup/2`.
  """
  def edit_message_reply_markup_with_retry(message_id, buttons, retries \\ @max_retries) do
    retry_429(fn -> edit_message_reply_markup(message_id, buttons) end, retries, "edit")
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
    * `:reply_to_message_id` — visually attach this message to another message.
  """
  def send_message(text, opts \\ []) do
    parse_mode = Keyword.get(opts, :parse_mode, "MarkdownV2")

    body =
      %{chat_id: chat_id(), text: text}
      |> maybe_put_parse_mode(parse_mode)
      |> maybe_put_reply_parameters(opts[:reply_to_message_id])

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

  def send_with_button_rows(text, rows, opts \\ []) do
    parse_mode = Keyword.get(opts, :parse_mode, "MarkdownV2")

    inline_keyboard =
      Enum.map(rows, fn row ->
        Enum.map(row, fn [label, data] -> %{text: label, callback_data: data} end)
      end)

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

  @doc """
  Splits Telegram HTML without cutting tags or entities.

  Open formatting is closed on each chunk and reopened on the next. The input
  is expected to contain only Telegram-supported, balanced HTML generated by
  `ClaudeNotify.MessageFormatter`.
  """
  def html_chunk(html, limit \\ @telegram_html_limit)
      when is_binary(html) and is_integer(limit) and limit > 0 do
    if String.length(html) <= limit do
      [html]
    else
      html
      |> tokenize_html()
      |> Enum.reduce(%{chunks: [], current: "", stack: [], payload?: false}, fn token, state ->
        append_html_token(state, token, limit)
      end)
      |> flush_html_chunk()
      |> Map.fetch!(:chunks)
      |> Enum.reverse()
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

  defp send_html_chunk_with_fallback(text, retries, opts) do
    case send_with_429_retry(text, retries, opts) do
      {:error, {400, body}} = error ->
        if telegram_parse_error?(body) do
          Logger.warning("Telegram rejected HTML formatting; retrying chunk as plain text")

          plain_opts = Keyword.put(opts, :parse_mode, nil)
          send_with_429_retry(html_to_plain(text), retries, plain_opts)
        else
          error
        end

      other ->
        other
    end
  end

  defp telegram_parse_error?(body) do
    description =
      case body do
        %{"description" => value} when is_binary(value) -> value
        value when is_binary(value) -> value
        _ -> ""
      end

    Regex.match?(~r/(can't parse entities|parse entities|find end of the entity)/i, description)
  end

  defp maybe_drop_reply(opts, 0), do: opts
  defp maybe_drop_reply(opts, _index), do: Keyword.delete(opts, :reply_to_message_id)

  defp maybe_put_reply_parameters(body, nil), do: body

  defp maybe_put_reply_parameters(body, message_id) when is_integer(message_id) do
    Map.put(body, :reply_parameters, %{
      message_id: message_id,
      allow_sending_without_reply: true
    })
  end

  defp maybe_put_reply_parameters(body, _message_id), do: body

  defp tokenize_html(html) do
    @telegram_html_token
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
  end

  defp append_html_token(state, token, limit) do
    cond do
      html_tag?(token) -> append_html_tag(state, token, limit)
      html_entity?(token) -> append_html_atomic(state, token, limit)
      true -> append_html_text(state, token, limit)
    end
  end

  defp append_html_tag(state, token, limit) do
    case parse_html_tag(token) do
      {:close, name} ->
        %{state | current: state.current <> token, stack: pop_html_tag(state.stack, name)}

      {:open, name} ->
        next_stack = [{name, token} | state.stack]

        required =
          String.length(state.current) + String.length(token) + close_suffix_length(next_stack)

        state =
          if required > limit and state.payload?, do: flush_html_chunk(state), else: state

        %{state | current: state.current <> token, stack: [{name, token} | state.stack]}

      :self_closing ->
        append_html_atomic(state, token, limit)

      :unknown ->
        append_html_text(state, token, limit)
    end
  end

  defp append_html_atomic(state, token, limit) do
    available = html_available(state, limit)

    cond do
      String.length(token) <= available ->
        %{state | current: state.current <> token, payload?: true}

      state.payload? ->
        state |> flush_html_chunk() |> append_html_atomic(token, limit)

      true ->
        # A generated entity or tag should never be this large. Preserve it so
        # the API can reject it and the plain-text fallback can take over.
        %{state | current: state.current <> token, payload?: true}
    end
  end

  defp append_html_text(state, "", _limit), do: state

  defp append_html_text(state, text, limit) do
    available = html_available(state, limit)

    cond do
      String.length(text) <= available ->
        %{state | current: state.current <> text, payload?: true}

      available <= 0 and state.payload? ->
        state |> flush_html_chunk() |> append_html_text(text, limit)

      available <= 0 ->
        %{state | current: state.current <> text, payload?: true}

      true ->
        {part, rest} = split_html_text(text, available)
        state = %{state | current: state.current <> part, payload?: true} |> flush_html_chunk()
        append_html_text(state, rest, limit)
    end
  end

  defp split_html_text(text, limit) do
    {candidate, rest} = String.split_at(text, limit)

    preferred =
      ["\n\n", "\n", " "]
      |> Enum.find_value(fn separator ->
        case :binary.matches(candidate, separator) do
          [] -> nil
          matches -> matches |> List.last() |> elem(0) |> Kernel.+(byte_size(separator))
        end
      end)

    case preferred do
      nil -> {candidate, rest}
      byte_index when byte_index < div(byte_size(candidate), 2) -> {candidate, rest}
      byte_index -> :erlang.split_binary(text, byte_index)
    end
  end

  defp flush_html_chunk(%{payload?: false} = state), do: state

  defp flush_html_chunk(state) do
    chunk = state.current <> close_suffix(state.stack)

    %{
      state
      | chunks: [chunk | state.chunks],
        current: open_prefix(state.stack),
        payload?: false
    }
  end

  defp html_available(state, limit) do
    max(limit - String.length(state.current) - close_suffix_length(state.stack), 0)
  end

  defp open_prefix(stack), do: stack |> Enum.reverse() |> Enum.map_join(&elem(&1, 1))
  defp close_suffix(stack), do: Enum.map_join(stack, fn {name, _tag} -> "</#{name}>" end)

  defp close_suffix_length(stack) do
    Enum.reduce(stack, 0, fn {name, _tag}, total -> total + String.length(name) + 3 end)
  end

  defp pop_html_tag([{name, _tag} | rest], name), do: rest

  defp pop_html_tag(stack, name) do
    case Enum.split_while(stack, fn {open_name, _tag} -> open_name != name end) do
      {_before, []} -> stack
      {before, [_match | after_match]} -> before ++ after_match
    end
  end

  defp html_tag?(token), do: Regex.match?(@telegram_html_tag, token)
  defp html_entity?("&" <> _rest = token), do: String.ends_with?(token, ";")
  defp html_entity?(_token), do: false

  defp parse_html_tag(token) do
    cond do
      Regex.match?(~r/^<br\s*\/?\s*>$/i, token) ->
        :self_closing

      match = Regex.run(~r/^<\/([a-z][a-z0-9]*)\s*>$/i, token) ->
        [_, name] = match
        {:close, String.downcase(name)}

      match = Regex.run(~r/^<([a-z][a-z0-9]*)\b[^>]*>$/i, token) ->
        [_, name] = match
        {:open, String.downcase(name)}

      true ->
        :unknown
    end
  end

  defp html_to_plain(html) do
    html
    |> String.replace(~r/<br\s*\/?\s*>/i, "\n")
    |> String.replace(~r/<[^>]+>/u, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
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
