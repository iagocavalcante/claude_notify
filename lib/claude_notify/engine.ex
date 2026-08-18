defmodule ClaudeNotify.Engine do
  @moduledoc """
  Behaviour for a headless coding-agent CLI that `ClaudeNotify.JobRunner`
  drives as a `Port`.

  An implementation turns a job's (already rule-wrapped) prompt into a
  concrete OS command, and turns that command's stdout - one JSON object per
  line, e.g. Claude Code's `--output-format stream-json` - into the internal
  event shape `JobRunner` consumes: `:tool_use`, `:text`, `:result`,
  `:session`, or `:ignore` for engine-internal lines that carry no
  job-relevant information (rate-limit telemetry, hook echoes, ...).

  `parse_event/1` must never raise - malformed or unrecognized lines should
  come back as `{:error, reason}` so `JobRunner` can log and skip them
  without taking the job down over one bad line.
  """

  @type tool_use_event :: %{
          required(:name) => String.t(),
          required(:input) => term(),
          optional(:id) => String.t() | nil
        }

  @type result_event :: %{
          required(:session_id) => String.t() | nil,
          required(:status) => :ok | :error,
          required(:summary) => String.t() | nil
        }

  @type event ::
          {:tool_use, tool_use_event()}
          | {:text, String.t()}
          | {:result, result_event()}
          | {:session, String.t()}

  @doc """
  Builds `{executable, args}` to launch a fresh run of this engine for
  `prompt`. `opts` carries per-run configuration (e.g. a fixture engine's
  script path); the working directory is applied by the caller via the
  `Port`'s `:cd` option, not through `opts` or the command line.
  """
  @callback build_command(prompt :: String.t(), opts :: keyword()) :: {String.t(), [String.t()]}

  @doc """
  Builds `{executable, args}` to resume a prior run identified by
  `session_id`, continuing with `prompt`.
  """
  @callback resume_command(session_id :: String.t(), prompt :: String.t(), opts :: keyword()) ::
              {String.t(), [String.t()]}

  @doc """
  Parses one line of the engine's stdout into an internal event.

  Returns `:ignore` for lines that parse fine but carry nothing job-relevant,
  or `{:error, reason}` for a line that couldn't be parsed at all.

  `{:session, session_id}` and a `{:result, %{session_id: session_id}}` with
  a non-nil `session_id` are both legal ways to report the engine's
  session/thread id - `JobRunner` stores it from either. Use `:session` when
  an engine reports its id before the outcome (e.g. Claude's `system/init`
  and Codex's `thread.started`); retain it on `:result` as well when the
  engine repeats the identity there.
  """
  @callback parse_event(line :: String.t()) :: {:ok, event()} | :ignore | {:error, term()}
end
