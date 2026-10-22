defmodule ClaudeNotify.WorkspaceStore do
  @moduledoc "Durable schedules, expiring confirmations, and bounded app-action receipts."
  use GenServer

  @entry_fields [
    :chat_id,
    :conversation_id,
    :text,
    :expires_at,
    :project,
    :engine,
    :models,
    :paused,
    :last_job_id,
    :last_reported_job_id,
    :interval,
    :next_at,
    :prompt
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def get(server \\ __MODULE__, key), do: GenServer.call(server, {:get, key})
  def put(server \\ __MODULE__, key, value), do: GenServer.call(server, {:put, key, value})
  def take(server \\ __MODULE__, key), do: GenServer.call(server, {:take, key})
  def list(server \\ __MODULE__, kind), do: GenServer.call(server, {:list, kind})
  def receipt(server \\ __MODULE__, entry), do: GenServer.call(server, {:receipt, entry})

  @impl true
  def init(opts) do
    path =
      Keyword.get(
        opts,
        :path,
        Application.get_env(
          :claude_notify,
          :workspace_store_path,
          Path.join([System.user_home!(), ".claude_notify", "workspace.dat"])
        )
      )

    case read(path) do
      {:ok, entries} -> {:ok, %{path: path, entries: entries}}
      {:error, reason} -> {:stop, {:workspace_store_unreadable, reason}}
    end
  end

  @impl true
  def handle_call({:get, key}, _, state), do: {:reply, state.entries[key], state}

  def handle_call({:list, kind}, _, state) do
    entries = for {{^kind, id}, value} <- state.entries, do: {id, value}
    {:reply, Enum.sort_by(entries, &elem(&1, 0)), state}
  end

  def handle_call({:put, key, value}, _, state) do
    if is_map(value) and Enum.all?(Map.keys(value), &(&1 in @entry_fields)) do
      save_reply(state, Map.put(state.entries, key, value), :ok)
    else
      {:reply, {:error, :invalid_entry}, state}
    end
  end

  def handle_call({:take, key}, _, state) do
    {value, entries} = Map.pop(state.entries, key)
    save_reply(state, entries, {:ok, value})
  end

  def handle_call({:receipt, entry}, _, state) do
    entry =
      entry |> Map.take([:action, :target, :outcome]) |> Map.put(:at, System.system_time(:second))

    receipts = [entry | Map.get(state.entries, :receipts, [])] |> Enum.take(200)
    save_reply(state, Map.put(state.entries, :receipts, receipts), :ok)
  end

  defp save_reply(state, entries, reply) do
    case write(state.path, entries) do
      :ok -> {:reply, reply, %{state | entries: entries}}
      {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
    end
  end

  defp read(nil), do: {:ok, %{}}

  defp read(path) do
    case File.read(path) do
      {:ok, binary} ->
        case :erlang.binary_to_term(binary, [:safe]) do
          %{version: 1, entries: entries} when is_map(entries) -> {:ok, entries}
          _ -> {:error, :invalid_schema}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      error ->
        error
    end
  rescue
    ArgumentError -> {:error, :corrupt_store}
  end

  defp write(nil, _), do: :ok

  defp write(path, entries) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(path <> ".tmp", :erlang.term_to_binary(%{version: 1, entries: entries})),
         :ok <- File.chmod(path <> ".tmp", 0o600),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end
end
