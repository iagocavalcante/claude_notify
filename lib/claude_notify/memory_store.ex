defmodule ClaudeNotify.MemoryStore.Observation do
  @moduledoc "A bounded normalized lifecycle observation persisted by MemoryStore."

  @enforce_keys [
    :id,
    :ingest_key,
    :project_id,
    :project_name,
    :source,
    :engine,
    :session_id,
    :kind,
    :title,
    :body,
    :metadata,
    :created_at
  ]

  defstruct [
    :id,
    :ingest_key,
    :project_id,
    :project_name,
    :source,
    :engine,
    :session_id,
    :job_id,
    :source_event_id,
    :sequence,
    :kind,
    :title,
    :body,
    :metadata,
    :created_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          ingest_key: String.t(),
          project_id: String.t(),
          project_name: String.t(),
          source: :terminal | :dispatcher,
          engine: String.t(),
          session_id: String.t(),
          job_id: integer() | nil,
          source_event_id: String.t() | nil,
          sequence: non_neg_integer() | nil,
          kind: atom(),
          title: String.t(),
          body: String.t(),
          metadata: map(),
          created_at: integer()
        }
end

defmodule ClaudeNotify.MemoryStore do
  @moduledoc """
  Versioned, durable, idempotent storage for normalized lifecycle observations.

  This is deliberately a narrow raw-observation store. It follows the same
  atomic temp-file/rename pattern as the existing session and job stores and
  introduces no database dependency before the derived Markdown/FTS layer in
  the later memory-page issue.

  Writes are acknowledged only after the new snapshot is on disk. Observation
  retention and the longer-lived ingest-key window are bounded independently:
  evicting old observation bodies does not immediately make a replay eligible
  for insertion again.

  Schema changes must increment `@schema_version` and add an explicit load
  migration. Unknown versions fail closed to an empty in-memory store and are
  never decoded as the current shape accidentally.
  """

  use GenServer
  require Logger

  alias ClaudeNotify.MemoryStore.Observation
  alias ClaudeNotify.ProjectScope.Scope

  @schema_version 1
  @default_max_per_session 500
  @default_max_per_project 5_000
  @default_max_ingest_keys 50_000
  @default_max_title_bytes 160
  @default_max_body_bytes 2_000
  @default_max_metadata_entries 20
  @default_max_collection_entries 50

  @allowed_kinds [
    :session_start,
    :user_prompt,
    :tool_use,
    :notification,
    :assistant_text,
    :turn_stop,
    :result,
    :session_end,
    :job_completed,
    :job_failed
  ]

  defstruct schema_version: @schema_version,
            observations: %{},
            order: [],
            ingest_keys: %{},
            ingest_order: [],
            path: nil,
            limits: %{},
            load_error: nil

  # -- Client API --

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Persists one normalized observation or reports a prior replay."
  def ingest(pid \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(pid, {:ingest, attrs})
  end

  @doc "Lists observations oldest-first with optional project/session/job filters."
  def list, do: list(__MODULE__, [])
  def list(filters) when is_list(filters), do: list(__MODULE__, filters)
  def list(pid), do: list(pid, [])

  def list(pid, filters) do
    GenServer.call(pid, {:list, filters})
  end

  def count(pid \\ __MODULE__), do: GenServer.call(pid, :count)
  def clear(pid \\ __MODULE__), do: GenServer.call(pid, :clear)

  @doc false
  def schema_version, do: @schema_version

  # -- Server callbacks --

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    limits = limits(opts)
    loaded = load(path)
    {:ok, %{loaded | path: path, limits: limits}}
  end

  @impl true
  def handle_call({:ingest, _attrs}, _from, %{load_error: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, {:store_unavailable, reason}}, state}
  end

  @impl true
  def handle_call({:ingest, attrs}, _from, state) do
    with {:ok, normalized} <- normalize(attrs, state.limits) do
      case Map.fetch(state.ingest_keys, normalized.ingest_key) do
        {:ok, existing_id} ->
          {:reply, {:ok, :duplicate, Map.get(state.observations, existing_id)}, state}

        :error ->
          observation = struct!(Observation, normalized)

          new_state =
            state
            |> put_observation(observation)
            |> enforce_retention(observation)
            |> enforce_ingest_key_retention()

          case persist(new_state) do
            :ok -> {:reply, {:ok, :inserted, observation}, new_state}
            {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:list, filters}, _from, state) do
    observations =
      state.order
      |> Enum.map(&Map.get(state.observations, &1))
      |> Enum.reject(&is_nil/1)
      |> maybe_filter(:project_id, filters[:project_id])
      |> maybe_filter(:session_id, filters[:session_id])
      |> maybe_filter(:job_id, filters[:job_id])
      |> maybe_filter(:kind, filters[:kind])
      |> maybe_limit(filters[:limit])

    {:reply, observations, state}
  end

  @impl true
  def handle_call(:count, _from, state), do: {:reply, map_size(state.observations), state}

  @impl true
  def handle_call(:clear, _from, state) do
    cleared = %__MODULE__{path: state.path, limits: state.limits}

    case persist(cleared) do
      :ok -> {:reply, :ok, cleared}
      {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
    end
  end

  # -- Normalization --

  defp normalize(attrs, limits) do
    with %Scope{} = scope <- attrs[:project_scope],
         source when source in [:terminal, :dispatcher] <- attrs[:source],
         kind when kind in @allowed_kinds <- attrs[:kind],
         session_id when is_binary(session_id) and session_id != "" <- attrs[:session_id],
         ingest_key when is_binary(ingest_key) and ingest_key != "" <- attrs[:ingest_key] do
      canonical_key = hash("ingest:" <> truncate_utf8(ingest_key, 1_000))

      {:ok,
       %{
         id: "obs_" <> binary_part(canonical_key, 0, 24),
         ingest_key: canonical_key,
         project_id: scope.id,
         project_name: truncate_utf8(scope.name, 200),
         source: source,
         engine: normalize_engine(attrs[:engine]),
         session_id: truncate_utf8(session_id, 200),
         job_id: normalize_job_id(attrs[:job_id]),
         source_event_id: normalize_source_event_id(attrs[:source_event_id]),
         sequence: normalize_sequence(attrs[:sequence]),
         kind: kind,
         title: attrs[:title] |> to_text() |> redact() |> truncate_utf8(limits.max_title_bytes),
         body: attrs[:body] |> to_text() |> redact() |> truncate_utf8(limits.max_body_bytes),
         metadata:
           normalize_metadata(
             attrs[:metadata],
             limits.max_metadata_entries,
             limits.max_collection_entries
           ),
         created_at: normalize_timestamp(attrs[:created_at])
       }}
    else
      nil -> {:error, :unresolved_project_scope}
      _ -> {:error, :invalid_observation}
    end
  end

  defp normalize_engine("codex"), do: "codex"
  defp normalize_engine(_), do: "claude"

  defp normalize_job_id(id) when is_integer(id) and id >= 0, do: id
  defp normalize_job_id(_), do: nil

  defp normalize_source_event_id(id) when is_binary(id), do: truncate_utf8(id, 240)
  defp normalize_source_event_id(_), do: nil

  defp normalize_sequence(sequence) when is_integer(sequence) and sequence >= 0, do: sequence
  defp normalize_sequence(_), do: nil

  defp normalize_timestamp(value) when is_integer(value) and value > 0, do: value
  defp normalize_timestamp(_), do: System.system_time(:millisecond)

  defp normalize_metadata(metadata, max_entries, max_collection_entries) when is_map(metadata) do
    metadata
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(max_entries)
    |> Map.new(fn {key, value} ->
      {normalize_metadata_key(key), normalize_metadata_value(value, max_collection_entries)}
    end)
  end

  defp normalize_metadata(_metadata, _max_entries, _max_collection_entries), do: %{}

  defp normalize_metadata_key(key), do: key |> to_string() |> truncate_utf8(80)

  defp normalize_metadata_value(value, _max) when is_boolean(value) or is_number(value), do: value
  defp normalize_metadata_value(nil, _max), do: nil

  defp normalize_metadata_value(value, max) when is_list(value) do
    value
    |> Enum.take(max)
    |> Enum.map(&(to_text(&1) |> redact() |> truncate_utf8(500)))
  end

  defp normalize_metadata_value(value, _max),
    do: value |> to_text() |> redact() |> truncate_utf8(1_000)

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value

  defp to_text(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp to_text(_value), do: ""

  # Bounded defense-in-depth for the user-facing text fields capture keeps.
  # Tool arguments and environment maps never reach this function at all.
  defp redact(text) do
    text
    |> String.replace(
      ~r/(?i)\b(api[_-]?key|access[_-]?token|auth[_-]?token|password|passwd|secret)\b\s*[:=]\s*[^\s,;]+/u,
      "\\1=[REDACTED]"
    )
    |> String.replace(~r/(?i)\bBearer\s+[A-Za-z0-9._~+\/-]+=*/u, "Bearer [REDACTED]")
    |> String.replace(~r/\bsk-[A-Za-z0-9_-]{12,}\b/u, "[REDACTED_TOKEN]")
  end

  defp truncate_utf8(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_utf8(text, max_bytes) do
    marker = "..."

    if max_bytes <= byte_size(marker) do
      binary_part(marker, 0, max_bytes)
    else
      prefix_bytes = max_bytes - byte_size(marker)
      prefix = binary_part(text, 0, prefix_bytes) |> valid_utf8_prefix()
      prefix <> marker
    end
  end

  defp valid_utf8_prefix(<<>>), do: ""

  defp valid_utf8_prefix(binary) do
    if String.valid?(binary) do
      binary
    else
      valid_utf8_prefix(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  # -- Retention --

  defp put_observation(state, observation) do
    %{
      state
      | observations: Map.put(state.observations, observation.id, observation),
        order: state.order ++ [observation.id],
        ingest_keys: Map.put(state.ingest_keys, observation.ingest_key, observation.id),
        ingest_order: state.ingest_order ++ [observation.ingest_key]
    }
  end

  defp enforce_retention(state, observation) do
    state
    |> retain_matching(
      fn item ->
        item.project_id == observation.project_id and item.session_id == observation.session_id
      end,
      state.limits.max_per_session
    )
    |> retain_matching(&(&1.project_id == observation.project_id), state.limits.max_per_project)
  end

  defp retain_matching(state, predicate, max) do
    matching_ids =
      Enum.filter(state.order, fn id ->
        case Map.get(state.observations, id) do
          nil -> false
          observation -> predicate.(observation)
        end
      end)

    drop_ids = Enum.take(matching_ids, max(length(matching_ids) - max, 0))

    if drop_ids == [] do
      state
    else
      drop_set = MapSet.new(drop_ids)

      %{
        state
        | observations: Map.drop(state.observations, drop_ids),
          order: Enum.reject(state.order, &MapSet.member?(drop_set, &1))
      }
    end
  end

  defp enforce_ingest_key_retention(state) do
    overflow = max(length(state.ingest_order) - state.limits.max_ingest_keys, 0)
    {drop_keys, keep_keys} = Enum.split(state.ingest_order, overflow)

    %{
      state
      | ingest_keys: Map.drop(state.ingest_keys, drop_keys),
        ingest_order: keep_keys
    }
  end

  defp maybe_filter(items, _field, nil), do: items
  defp maybe_filter(items, field, value), do: Enum.filter(items, &(Map.get(&1, field) == value))

  defp maybe_limit(items, nil), do: items

  defp maybe_limit(items, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(items, -limit)

  defp maybe_limit(items, _invalid), do: items

  # -- Persistence --

  defp persist(%{path: nil}), do: :ok

  defp persist(state) do
    data =
      :erlang.term_to_binary(%{
        schema_version: @schema_version,
        observations: state.observations,
        order: state.order,
        ingest_keys: state.ingest_keys,
        ingest_order: state.ingest_order
      })

    tmp_path = state.path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- File.write(tmp_path, data),
         :ok <- File.chmod(tmp_path, 0o600),
         :ok <- File.rename(tmp_path, state.path) do
      :ok
    end
  end

  defp load(nil), do: %__MODULE__{}

  defp load(path) do
    with true <- File.regular?(path),
         {:ok, binary} <- File.read(path),
         {:ok, data} <- safe_decode(binary),
         {:ok, state} <- load_version(data) do
      state
    else
      false ->
        %__MODULE__{}

      {:error, reason} ->
        Logger.warning("MemoryStore: could not load #{inspect(path)}: #{inspect(reason)}")
        %__MODULE__{load_error: reason}

      _ ->
        Logger.warning("MemoryStore: invalid store at #{inspect(path)}")
        %__MODULE__{load_error: :invalid_store}
    end
  end

  defp load_version(%{
         schema_version: @schema_version,
         observations: observations,
         order: order,
         ingest_keys: ingest_keys,
         ingest_order: ingest_order
       })
       when is_map(observations) and is_list(order) and is_map(ingest_keys) and
              is_list(ingest_order) do
    {:ok,
     %__MODULE__{
       observations: observations,
       order: order,
       ingest_keys: ingest_keys,
       ingest_order: ingest_order
     }}
  end

  defp load_version(%{schema_version: version}), do: {:error, {:unsupported_schema, version}}
  defp load_version(_data), do: {:error, :missing_schema_version}

  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :unsafe_or_corrupt_term}
  end

  defp limits(opts) do
    config = Application.get_env(:claude_notify, :memory, %{})

    %{
      max_per_session:
        positive_limit(
          opts[:max_per_session] || config[:max_observations_per_session],
          @default_max_per_session
        ),
      max_per_project:
        positive_limit(
          opts[:max_per_project] || config[:max_observations_per_project],
          @default_max_per_project
        ),
      max_ingest_keys:
        positive_limit(
          opts[:max_ingest_keys] || config[:max_ingest_keys],
          @default_max_ingest_keys
        ),
      max_title_bytes:
        positive_limit(
          opts[:max_title_bytes] || config[:max_title_bytes],
          @default_max_title_bytes
        ),
      max_body_bytes:
        positive_limit(opts[:max_body_bytes] || config[:max_body_bytes], @default_max_body_bytes),
      max_metadata_entries:
        positive_limit(
          opts[:max_metadata_entries] || config[:max_metadata_entries],
          @default_max_metadata_entries
        ),
      max_collection_entries:
        positive_limit(
          opts[:max_collection_entries] || config[:max_collection_entries],
          @default_max_collection_entries
        )
    }
  end

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp default_path do
    Application.get_env(
      :claude_notify,
      :memory_store_path,
      Path.join([System.user_home!(), ".claude_notify", "memory_store.dat"])
    )
  end
end
