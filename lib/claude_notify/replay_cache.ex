defmodule ClaudeNotify.ReplayCache do
  @moduledoc """
  Simple in-memory replay cache for signed webhook requests.
  """

  @table :claude_notify_replay_cache

  @doc """
  Returns `:ok` when the key was newly inserted, `:replay` when seen before.
  """
  def check_and_put(key, ttl_seconds) when is_binary(key) and ttl_seconds > 0 do
    table = ensure_table!()
    now = System.system_time(:second)

    cleanup_expired(table, now)

    case :ets.lookup(table, key) do
      [{^key, expires_at}] when expires_at > now ->
        :replay

      [{^key, _expires_at}] ->
        :ets.delete(table, key)
        insert_key(table, key, now + ttl_seconds)

      [] ->
        insert_key(table, key, now + ttl_seconds)
    end
  end

  def check_and_put(_key, _ttl_seconds), do: :replay

  def clear do
    table = ensure_table!()
    :ets.delete_all_objects(table)
    :ok
  end

  defp insert_key(table, key, expires_at) do
    if :ets.insert_new(table, {key, expires_at}) do
      :ok
    else
      :replay
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, {:read_concurrency, true}])

      tid ->
        tid
    end
  end

  defp cleanup_expired(table, now) do
    match_spec = [
      {{:"$1", :"$2"}, [{:"=<", :"$2", now}], [true]}
    ]

    :ets.select_delete(table, match_spec)
    :ok
  end
end
