defmodule ClaudeNotify.ReplayCache do
  @moduledoc """
  Simple in-memory replay cache for signed webhook requests.

  The supervised server owns the named ETS table for the lifetime of the
  application. Request processes only perform concurrent reads and writes;
  they never race to create the table or accidentally own a table that
  disappears when the request exits.
  """

  use GenServer

  @table :claude_notify_replay_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    @table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    {:ok, %{}}
  end

  @doc """
  Returns `:ok` when the key was newly inserted, `:replay` when seen before.
  """
  def check_and_put(key, ttl_seconds) when is_binary(key) and ttl_seconds > 0 do
    now = System.system_time(:second)

    cleanup_expired(now)

    case :ets.lookup(@table, key) do
      [{^key, expires_at}] when expires_at > now ->
        :replay

      [{^key, _expires_at}] ->
        :ets.delete(@table, key)
        insert_key(key, now + ttl_seconds)

      [] ->
        insert_key(key, now + ttl_seconds)
    end
  end

  def check_and_put(_key, _ttl_seconds), do: :replay

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp insert_key(key, expires_at) do
    if :ets.insert_new(@table, {key, expires_at}) do
      :ok
    else
      :replay
    end
  end

  defp cleanup_expired(now) do
    match_spec = [
      {{:"$1", :"$2"}, [{:"=<", :"$2", now}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
    :ok
  end
end
