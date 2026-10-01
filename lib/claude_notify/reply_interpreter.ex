defmodule ClaudeNotify.ReplyInterpreter do
  @moduledoc """
  Uses TypeSafe's Jev model (https://typesafe.ai) to decide whether a
  free-text Telegram reply to a pending permission/choice prompt is
  confidently equivalent to pressing one of today's shortcut buttons -
  "yes" | "yes_dont_ask" | "no" | "escape" | "opt_1".."opt_9", the same
  codes `ClaudeNotify.TelegramPoller.shortcut_response/1` returns for an
  exact match, and that `ClaudeNotify.TerminalInjector.send_response/2`
  knows how to press.

  This only covers the remainder `shortcut_response/1` leaves as `nil`:
  free text such as "sim, pode rodar" or "the second one". It never runs
  for an idle session (no pending question) - see
  `ClaudeNotify.TelegramPoller`'s `pending_question_context/1`, which
  gates every call into this module.

  Disabled (returns `:free_text` without any HTTP call) unless
  `:claude_notify, :typesafe_api_key` is configured - the feature is off
  by default, and a missing key is a normal, silent state, not an error.
  """

  require Logger

  @endpoint "https://api.typesafe.ai/v1/systemone"
  @model "jev-latest"

  # How sure the model must be before we press a button on the user's
  # behalf instead of just forwarding their raw text. Both are deliberately
  # strict: pressing the wrong button (denying real work, or dropping an
  # instruction the user attached to their approval) is worse than falling
  # back to plain text injection, which was always safe.
  @min_choice_confidence 0.9
  @min_lossless 0.7

  @doc "Builds the config `interpret/4` reads Application env from by default."
  def default_config do
    %{
      api_key: Application.get_env(:claude_notify, :typesafe_api_key),
      model: Application.get_env(:claude_notify, :typesafe_model, @model),
      min_choice_confidence: @min_choice_confidence,
      min_lossless: @min_lossless,
      req_options: []
    }
  end

  @doc """
  Interprets `reply_text` against the pending `question_text` and its
  numbered `options` (a list of `{number, label}` pairs, as returned by
  `ClaudeNotify.EventHandler.parse_numbered_options/1` - empty when the
  prompt is a plain yes/no/escape one rather than a numbered menu).

  Returns `{:ok, response_code}` when the model is confident the reply is
  a plain button-equivalent that loses nothing the user said, `:free_text`
  otherwise - including when the feature is off, or on any HTTP error,
  non-200 response, timeout, or unexpected body shape.
  """
  def interpret(reply_text, question_text, options, config \\ default_config())

  def interpret(_reply_text, _question_text, _options, %{api_key: api_key})
      when api_key in [nil, ""] do
    :free_text
  end

  def interpret(reply_text, question_text, options, config)
      when is_binary(reply_text) and is_binary(question_text) and is_list(options) do
    body = request_body(reply_text, question_text, options, config)

    # ponytail: this runs synchronously inside the TelegramPoller GenServer,
    # bounded by the 3s receive_timeout below - a burst of interpreted
    # replies serializes behind it. Move it into a Task (mirroring the
    # watch-mode progress plumbing's self()-message pattern) if that
    # blocking ceiling ever shows up under real traffic.
    case Req.request(request_opts(config, body)) do
      {:ok, %{status: 200, body: %{"answers" => answers}}} when is_map(answers) ->
        classify(answers, Map.keys(body.questions["intent"].criteria), config)

      {:ok, %{status: status}} ->
        Logger.warning("ReplyInterpreter: TypeSafe returned status #{status}")
        :free_text

      {:error, reason} ->
        Logger.warning("ReplyInterpreter: TypeSafe request failed: #{inspect(reason)}")
        :free_text
    end
  end

  defp request_opts(config, body) do
    [
      method: :post,
      url: @endpoint,
      headers: [
        {"authorization", "Bearer #{config.api_key}"},
        {"content-type", "application/json"}
      ],
      json: body,
      retry: false,
      receive_timeout: 3_000
    ]
    |> Keyword.merge(config[:req_options] || [])
  end

  defp request_body(reply_text, question_text, options, config) do
    %{
      model: config[:model] || @model,
      state: %{
        prompt: question_text,
        options: Enum.map(options, fn {_number, label} -> label end),
        user_reply: reply_text
      },
      questions: %{
        "intent" => %{
          type: "choice",
          instructions:
            "Decide which single response `user_reply` maps to, given the pending " <>
              "prompt `prompt` and its numbered `options` (empty when the prompt is a " <>
              "plain yes/no/cancel one rather than a numbered menu). Pick a criterion " <>
              "only when the reply plainly and unambiguously matches it with nothing " <>
              "added, changed, or left out; otherwise pick free_text.",
          criteria: choice_criteria(options)
        },
        "lossless" => %{
          type: "noul",
          instructions:
            "Can `user_reply` be fully replaced by pressing a single button - a plain " <>
              "yes/no/don't-ask-again/cancel, or one of the numbered `options` when " <>
              "`options` is non-empty - without losing anything the user said?"
        }
      }
    }
  end

  defp choice_criteria([]) do
    %{
      "yes" =>
        "The user plainly approves or agrees, with no conditions, instructions, or " <>
          "alternatives attached.",
      "yes_dont_ask" =>
        "The user approves and explicitly asks not to be asked again, or says to " <>
          "always allow this from now on.",
      "no" =>
        "The user plainly refuses or declines, with no alternative suggested and no " <>
          "instruction attached.",
      "escape" => "The user wants to cancel, stop, or abort the current prompt entirely.",
      "free_text" =>
        "Anything else: the reply adds an instruction or condition, proposes an " <>
          "alternative, asks a question, or is unrelated to answering this prompt."
    }
  end

  defp choice_criteria(options) do
    numbered = Map.new(options, fn {number, label} -> {"opt_#{number}", label} end)

    Map.merge(numbered, %{
      "escape" =>
        "The user wants to cancel, stop, or abort the current prompt entirely, " <>
          "without choosing any of the numbered options.",
      "free_text" =>
        "Anything else: the reply adds an instruction or condition, proposes " <>
          "something not among the numbered options, asks a question, or is " <>
          "unrelated to choosing one of the options."
    })
  end

  defp classify(answers, offered_codes, config) do
    with %{"choice" => choice, "confidence" => confidence}
         when is_binary(choice) and is_number(confidence) <- answers["intent"],
         %{"noul" => lossless} when is_number(lossless) <- answers["lossless"],
         true <- choice != "free_text" and choice in offered_codes,
         true <- confidence >= (config[:min_choice_confidence] || @min_choice_confidence),
         true <- lossless >= (config[:min_lossless] || @min_lossless) do
      {:ok, choice}
    else
      _ -> :free_text
    end
  end
end
