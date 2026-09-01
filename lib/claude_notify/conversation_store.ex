defmodule ClaudeNotify.ConversationStore.Conversation do
  @moduledoc "A durable Telegram chat destination and its pending turns."

  @enforce_keys [:chat_id, :project, :project_id, :engine, :updated_at]
  defstruct [
    :chat_id,
    :project,
    :project_id,
    :engine,
    :head_job_id,
    :updated_at,
    pending: []
  ]

  @type t :: %__MODULE__{}
end

defmodule ClaudeNotify.ConversationStore do
  @moduledoc """
  Persists the conversational harness destination for each authorized chat.

  A conversation points at one canonical project, one currently selected
  engine, and the latest dispatcher job whose worktree is the conversation's
  workspace. Follow-up turns sent while that job is busy are durably queued
  and popped one at a time after each turn completes.
  """

  use GenServer
  require Logger

  alias ClaudeNotify.ConversationStore.Conversation
  alias ClaudeNotify.JobStore.Job
  alias ClaudeNotify.ProjectScope.Scope

  @schema_version 1
  @default_max_pending 10
  @default_max_prompt_bytes 8_000

  defstruct schema_version: @schema_version,
            conversations: %{},
            path: nil,
            max_pending: @default_max_pending,
            max_prompt_bytes: @default_max_prompt_bytes,
            load_error: nil

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def get(pid \\ __MODULE__, chat_id), do: GenServer.call(pid, {:get, chat_key(chat_id)})
  def list(pid \\ __MODULE__), do: GenServer.call(pid, :list)

  @doc "Selects a project and starts a fresh conversation in it."
  def select_project(pid \\ __MODULE__, chat_id, %Scope{} = scope, engine) do
    GenServer.call(pid, {:select_project, chat_key(chat_id), scope, normalize_engine(engine)})
  end

  @doc "Changes the agent used by future turns without changing the workspace."
  def select_engine(pid \\ __MODULE__, chat_id, engine) do
    GenServer.call(pid, {:select_engine, chat_key(chat_id), normalize_engine(engine)})
  end

  @doc "Binds the latest dispatcher job as the conversation head."
  def bind_job(pid \\ __MODULE__, chat_id, %Job{} = job) do
    GenServer.call(pid, {:bind_job, chat_key(chat_id), job})
  end

  @doc "Clears the job chain and pending turns while retaining project and engine."
  def fresh(pid \\ __MODULE__, chat_id), do: GenServer.call(pid, {:fresh, chat_key(chat_id)})

  @doc "Durably queues a follow-up turn for the selected conversation."
  def enqueue(pid \\ __MODULE__, chat_id, prompt, engine \\ nil) do
    GenServer.call(pid, {:enqueue, chat_key(chat_id), prompt, engine})
  end

  @doc "Atomically removes and returns the oldest pending turn."
  def pop_pending(pid \\ __MODULE__, chat_id) do
    GenServer.call(pid, {:pop_pending, chat_key(chat_id)})
  end

  def clear(pid \\ __MODULE__), do: GenServer.call(pid, :clear)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    state = load(path)

    {:ok,
     %{
       state
       | path: path,
         max_pending: positive(opts[:max_pending], configured(:conversation_max_pending, 10)),
         max_prompt_bytes:
           positive(opts[:max_prompt_bytes], configured(:conversation_max_prompt_bytes, 8_000))
     }}
  end

  @impl true
  def handle_call(request, _from, %{load_error: reason} = state)
      when not is_nil(reason) and request != :clear do
    {:reply, {:error, {:store_unavailable, reason}}, state}
  end

  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.conversations, key), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, state.conversations |> Map.values() |> Enum.sort_by(& &1.updated_at, :desc), state}
  end

  def handle_call({:select_project, key, scope, engine}, _from, state) do
    conversation = %Conversation{
      chat_id: key,
      project: scope.name,
      project_id: scope.id,
      engine: engine,
      head_job_id: nil,
      pending: [],
      updated_at: now_ms()
    }

    put_and_reply(state, key, conversation)
  end

  def handle_call({:select_engine, key, engine}, _from, state) do
    case Map.get(state.conversations, key) do
      nil ->
        {:reply, {:error, :no_conversation}, state}

      conversation ->
        put_and_reply(state, key, %{conversation | engine: engine, updated_at: now_ms()})
    end
  end

  def handle_call({:bind_job, key, job}, _from, state) do
    case Map.get(state.conversations, key) do
      nil ->
        {:reply, {:error, :no_conversation}, state}

      conversation ->
        updated = %{
          conversation
          | project: job.project,
            project_id: job.project_id || conversation.project_id,
            engine: job.engine,
            head_job_id: job.id,
            updated_at: now_ms()
        }

        put_and_reply(state, key, updated)
    end
  end

  def handle_call({:fresh, key}, _from, state) do
    case Map.get(state.conversations, key) do
      nil ->
        {:reply, {:error, :no_conversation}, state}

      conversation ->
        put_and_reply(state, key, %{
          conversation
          | head_job_id: nil,
            pending: [],
            updated_at: now_ms()
        })
    end
  end

  def handle_call({:enqueue, key, prompt, engine}, _from, state) do
    case Map.get(state.conversations, key) do
      nil ->
        {:reply, {:error, :no_conversation}, state}

      %{pending: pending} when length(pending) >= state.max_pending ->
        {:reply, {:error, :queue_full}, state}

      conversation ->
        prompt = bounded_prompt(prompt, state.max_prompt_bytes)

        if prompt == "" do
          {:reply, {:error, :empty_prompt}, state}
        else
          turn = %{
            prompt: prompt,
            engine: normalize_engine(engine || conversation.engine),
            enqueued_at: now_ms()
          }

          updated = %{
            conversation
            | pending: conversation.pending ++ [turn],
              updated_at: now_ms()
          }

          case persist(%{state | conversations: Map.put(state.conversations, key, updated)}) do
            :ok ->
              {:reply, {:ok, length(updated.pending)},
               %{state | conversations: Map.put(state.conversations, key, updated)}}

            {:error, reason} ->
              {:reply, {:error, {:persist_failed, reason}}, state}
          end
        end
    end
  end

  def handle_call({:pop_pending, key}, _from, state) do
    case Map.get(state.conversations, key) do
      nil ->
        {:reply, {:error, :no_conversation}, state}

      %{pending: []} ->
        {:reply, :empty, state}

      %{pending: [turn | rest]} = conversation ->
        updated = %{conversation | pending: rest, updated_at: now_ms()}
        next = %{state | conversations: Map.put(state.conversations, key, updated)}

        case persist(next) do
          :ok -> {:reply, {:ok, turn}, next}
          {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
        end
    end
  end

  def handle_call(:clear, _from, state) do
    next = %{state | conversations: %{}, load_error: nil}

    case persist(next) do
      :ok -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
    end
  end

  defp put_and_reply(state, key, conversation) do
    next = %{state | conversations: Map.put(state.conversations, key, conversation)}

    case persist(next) do
      :ok -> {:reply, {:ok, conversation}, next}
      {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
    end
  end

  defp chat_key(value) when is_binary(value), do: value
  defp chat_key(value), do: to_string(value)
  defp normalize_engine("codex"), do: "codex"
  defp normalize_engine(_), do: "claude"

  defp bounded_prompt(value, max) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) <= max do
      value
    else
      value |> binary_part(0, max) |> valid_utf8_prefix()
    end
  end

  defp bounded_prompt(_value, _max), do: ""
  defp valid_utf8_prefix(""), do: ""

  defp valid_utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> valid_utf8_prefix()
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp configured(key, default),
    do: Application.get_env(:claude_notify, :memory, %{})[key] || default

  defp persist(%{path: nil}), do: :ok

  defp persist(state) do
    binary =
      :erlang.term_to_binary(%{
        schema_version: @schema_version,
        conversations: state.conversations
      })

    temporary = state.path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- File.write(temporary, binary),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, state.path) do
      :ok
    end
  end

  defp load(nil), do: %__MODULE__{}

  defp load(path) do
    with true <- File.regular?(path),
         {:ok, binary} <- File.read(path),
         {:ok, data} <- safe_decode(binary),
         {:ok, conversations} <- load_version(data) do
      %__MODULE__{conversations: normalize_conversations(conversations)}
    else
      false ->
        %__MODULE__{}

      {:error, reason} ->
        Logger.warning("ConversationStore: could not load #{inspect(path)}: #{inspect(reason)}")
        %__MODULE__{load_error: reason}

      _ ->
        %__MODULE__{load_error: :invalid_store}
    end
  end

  defp load_version(%{schema_version: @schema_version, conversations: conversations})
       when is_map(conversations),
       do: {:ok, conversations}

  defp load_version(%{schema_version: version}), do: {:error, {:unsupported_schema, version}}
  defp load_version(_), do: {:error, :missing_schema_version}

  defp normalize_conversations(conversations) do
    allowed = Map.keys(Conversation.__struct__())

    Map.new(conversations, fn {key, value} ->
      attrs = value |> Map.delete(:__struct__) |> Map.take(allowed)
      {chat_key(key), struct(Conversation, attrs)}
    end)
  end

  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :unsafe_or_corrupt_term}
  end

  defp default_path do
    Application.get_env(
      :claude_notify,
      :conversation_store_path,
      Path.join([System.user_home!(), ".claude_notify", "conversations.dat"])
    )
  end
end
