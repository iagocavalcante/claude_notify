defmodule ClaudeNotify.HandoffStore.Handoff do
  @moduledoc "A portable, typed checkpoint between coding-agent sessions."

  @enforce_keys [
    :id,
    :state,
    :kind,
    :project_id,
    :project_name,
    :cwd_relative,
    :source,
    :source_engine,
    :source_session_id,
    :summary,
    :open_questions,
    :next_steps,
    :files_touched,
    :generation,
    :created_at,
    :updated_at
  ]

  defstruct [
    :id,
    :state,
    :kind,
    :project_id,
    :project_name,
    :cwd_relative,
    :source,
    :source_engine,
    :source_session_id,
    :source_engine_session_id,
    :source_job_id,
    :summary,
    :open_questions,
    :next_steps,
    :files_touched,
    :generation,
    :created_at,
    :updated_at,
    :accepted_by_engine,
    :accepted_by_session_id,
    :accepted_by_job_id,
    :accepted_at
  ]

  @type t :: %__MODULE__{}
end

defmodule ClaudeNotify.HandoffStore do
  @moduledoc """
  Durable handoff state machine with idempotent generation and claiming.

  Automatic handoffs are unique per project/source session/generation. A
  newer generation expires the previous open automatic checkpoint from that
  source. Claims are persisted atomically with the `open -> accepted`
  transition; retrying with the same receiver returns the same handoff after
  either a network failure or an application restart.
  """

  use GenServer
  require Logger

  alias ClaudeNotify.HandoffStore.Handoff
  alias ClaudeNotify.ProjectScope.Scope

  @schema_version 1
  @states [:open, :accepted, :expired]
  @valid_transitions %{open: [:accepted, :expired], accepted: [], expired: []}
  @default_max_handoffs 5_000
  @default_max_summary_bytes 4_000
  @default_max_items 20
  @default_max_item_bytes 500

  defstruct schema_version: @schema_version,
            handoffs: %{},
            order: [],
            generations: %{},
            claims: %{},
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

  @doc "Creates or refreshes one automatic handoff without replay duplicates."
  def upsert_automatic(pid \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(pid, {:upsert_automatic, attrs})
  end

  @doc "Atomically selects and claims the newest eligible handoff."
  def claim(pid \\ __MODULE__, %Scope{} = scope, receiver) when is_map(receiver) do
    GenServer.call(pid, {:claim, scope, receiver})
  end

  @doc "Returns the newest eligible open handoff without mutating it."
  def eligible(pid \\ __MODULE__, %Scope{} = scope, receiver) when is_map(receiver) do
    GenServer.call(pid, {:eligible, scope, receiver})
  end

  def transition(pid \\ __MODULE__, id, state) when state in @states do
    GenServer.call(pid, {:transition, id, state})
  end

  def get(pid \\ __MODULE__, id), do: GenServer.call(pid, {:get, id})
  def list(pid \\ __MODULE__, filters \\ []), do: GenServer.call(pid, {:list, filters})
  def clear(pid \\ __MODULE__), do: GenServer.call(pid, :clear)

  # -- Server callbacks --

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    state = load(path)

    {:ok,
     %{
       state
       | path: path,
         limits: %{
           max_handoffs: limit(opts[:max_handoffs], @default_max_handoffs),
           max_summary_bytes:
             limit(
               opts[:max_summary_bytes],
               configured(:max_handoff_summary_bytes, @default_max_summary_bytes)
             ),
           max_items: limit(opts[:max_items], configured(:max_handoff_items, @default_max_items)),
           max_item_bytes:
             limit(
               opts[:max_item_bytes],
               configured(:max_handoff_item_bytes, @default_max_item_bytes)
             )
         }
     }}
  end

  @impl true
  def handle_call({:upsert_automatic, _attrs}, _from, %{load_error: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, {:store_unavailable, reason}}, state}
  end

  def handle_call({:upsert_automatic, attrs}, _from, state) do
    with {:ok, normalized, generation_key, source_key} <- normalize(attrs, state.limits) do
      case Map.fetch(state.generations, generation_key) do
        {:ok, id} ->
          {:reply, {:ok, :duplicate, Map.get(state.handoffs, id)}, state}

        :error ->
          handoff = struct!(Handoff, normalized)

          next =
            state
            |> expire_open_source(source_key, handoff.updated_at)
            |> put_handoff(handoff, generation_key)
            |> enforce_retention()

          case persist(next) do
            :ok -> {:reply, {:ok, :inserted, handoff}, next}
            {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:claim, _scope, _receiver}, _from, %{load_error: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, {:store_unavailable, reason}}, state}
  end

  def handle_call({:claim, scope, receiver}, _from, state) do
    with {:ok, receiver} <- normalize_receiver(scope, receiver) do
      case Map.fetch(state.claims, receiver.claim_key) do
        {:ok, handoff_id} ->
          case Map.get(state.handoffs, handoff_id) do
            %Handoff{} = handoff -> {:reply, {:ok, :existing, handoff}, state}
            nil -> claim_new(state, scope, receiver)
          end

        :error ->
          claim_new(state, scope, receiver)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:eligible, scope, receiver}, _from, state) do
    with {:ok, normalized} <- normalize_receiver(scope, receiver) do
      {:reply, newest_eligible(state, scope, normalized), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:transition, id, next_state}, _from, state) do
    case Map.get(state.handoffs, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Handoff{state: current} = handoff ->
        if next_state in Map.fetch!(@valid_transitions, current) do
          updated = %{handoff | state: next_state, updated_at: now_ms()}
          next = %{state | handoffs: Map.put(state.handoffs, id, updated)}

          case persist(next) do
            :ok -> {:reply, {:ok, updated}, next}
            {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
          end
        else
          {:reply, {:error, {:invalid_transition, current, next_state}}, state}
        end
    end
  end

  def handle_call({:get, id}, _from, state), do: {:reply, Map.get(state.handoffs, id), state}

  def handle_call({:list, filters}, _from, state) do
    items =
      state.order
      |> Enum.map(&Map.get(state.handoffs, &1))
      |> Enum.reject(&is_nil/1)
      |> maybe_filter(:project_id, filters[:project_id])
      |> maybe_filter(:source_session_id, filters[:source_session_id])
      |> maybe_filter(:source_job_id, filters[:source_job_id])
      |> maybe_filter(:state, filters[:state])

    {:reply, items, state}
  end

  def handle_call(:clear, _from, state) do
    cleared = %__MODULE__{path: state.path, limits: state.limits}

    case persist(cleared) do
      :ok -> {:reply, :ok, cleared}
      {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
    end
  end

  # -- Generation and selection --

  defp normalize(attrs, limits) do
    with %Scope{} = scope <- attrs[:project_scope],
         source when source in [:terminal, :dispatcher] <- attrs[:source],
         session_id when is_binary(session_id) and session_id != "" <- attrs[:source_session_id],
         generation when is_binary(generation) and generation != "" <- attrs[:generation] do
      timestamp = normalize_timestamp(attrs[:created_at])
      generation_key = hash(Enum.join([scope.id, to_string(source), session_id, generation], ":"))
      source_key = {scope.id, source, session_id}

      {:ok,
       %{
         id: "handoff_" <> binary_part(generation_key, 0, 24),
         state: :open,
         kind: :automatic,
         project_id: scope.id,
         project_name: text(scope.name, 200),
         cwd_relative: relative_cwd(scope),
         source: source,
         source_engine: normalize_engine(attrs[:source_engine]),
         source_session_id: text(session_id, 200),
         source_engine_session_id: optional_text(attrs[:source_engine_session_id], 200),
         source_job_id: normalize_job_id(attrs[:source_job_id]),
         summary: text(attrs[:summary], limits.max_summary_bytes),
         open_questions: items(attrs[:open_questions], limits),
         next_steps: items(attrs[:next_steps], limits),
         files_touched: safe_files(attrs[:files_touched], limits),
         generation: text(generation, 240),
         created_at: timestamp,
         updated_at: timestamp,
         accepted_by_engine: nil,
         accepted_by_session_id: nil,
         accepted_by_job_id: nil,
         accepted_at: nil
       }, generation_key, source_key}
    else
      nil -> {:error, :unresolved_project_scope}
      _ -> {:error, :invalid_handoff}
    end
  end

  defp normalize_receiver(scope, attrs) do
    receiver_id = attrs[:session_id] || receiver_job_id(attrs[:job_id])

    if is_binary(receiver_id) and receiver_id != "" do
      claim_key = hash(Enum.join([scope.id, receiver_id], ":"))

      {:ok,
       %{
         claim_key: claim_key,
         session_id: text(receiver_id, 200),
         job_id: normalize_job_id(attrs[:job_id]),
         engine: normalize_engine(attrs[:engine]),
         resume_session_id: optional_text(attrs[:resume_session_id], 200),
         cwd_relative: relative_cwd(scope)
       }}
    else
      {:error, :invalid_receiver}
    end
  end

  defp receiver_job_id(id) when is_integer(id) and id >= 0, do: "job:#{id}"
  defp receiver_job_id(_), do: nil

  defp claim_new(state, scope, receiver) do
    case newest_eligible(state, scope, receiver) do
      nil ->
        {:reply, :none, state}

      %Handoff{} = handoff ->
        timestamp = now_ms()

        accepted = %{
          handoff
          | state: :accepted,
            updated_at: timestamp,
            accepted_at: timestamp,
            accepted_by_engine: receiver.engine,
            accepted_by_session_id: receiver.session_id,
            accepted_by_job_id: receiver.job_id
        }

        next = %{
          state
          | handoffs: Map.put(state.handoffs, handoff.id, accepted),
            claims: Map.put(state.claims, receiver.claim_key, handoff.id)
        }

        case persist(next) do
          :ok -> {:reply, {:ok, :claimed, accepted}, next}
          {:error, reason} -> {:reply, {:error, {:persist_failed, reason}}, state}
        end
    end
  end

  defp newest_eligible(state, scope, receiver) do
    state.order
    |> Enum.reverse()
    |> Enum.map(&Map.get(state.handoffs, &1))
    |> Enum.find(fn
      %Handoff{} = handoff ->
        handoff.project_id == scope.id and handoff.state == :open and
          handoff.source_session_id != receiver.session_id and
          (is_nil(receiver.resume_session_id) or
             handoff.source_engine_session_id != receiver.resume_session_id) and
          cwd_compatible?(handoff.cwd_relative, receiver.cwd_relative)

      _ ->
        false
    end)
  end

  defp cwd_compatible?(left, right) do
    left == right or left == "." or right == "." or
      String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")
  end

  defp expire_open_source(state, source_key, timestamp) do
    handoffs =
      Map.new(state.handoffs, fn {id, handoff} ->
        if source_key(handoff) == source_key and handoff.kind == :automatic and
             handoff.state == :open do
          {id, %{handoff | state: :expired, updated_at: timestamp}}
        else
          {id, handoff}
        end
      end)

    %{state | handoffs: handoffs}
  end

  defp source_key(handoff),
    do: {handoff.project_id, handoff.source, handoff.source_session_id}

  defp put_handoff(state, handoff, generation_key) do
    %{
      state
      | handoffs: Map.put(state.handoffs, handoff.id, handoff),
        order: state.order ++ [handoff.id],
        generations: Map.put(state.generations, generation_key, handoff.id)
    }
  end

  defp enforce_retention(state) do
    overflow = max(length(state.order) - state.limits.max_handoffs, 0)
    {drop_ids, keep_ids} = Enum.split(state.order, overflow)
    drop_set = MapSet.new(drop_ids)

    %{
      state
      | handoffs: Map.drop(state.handoffs, drop_ids),
        order: keep_ids,
        generations:
          Map.reject(state.generations, fn {_key, id} -> MapSet.member?(drop_set, id) end),
        claims: Map.reject(state.claims, fn {_key, id} -> MapSet.member?(drop_set, id) end)
    }
  end

  # -- Bounds and paths --

  defp relative_cwd(scope) do
    relative = Path.relative_to(scope.cwd, scope.worktree_root)
    if relative == "" or String.starts_with?(relative, "../"), do: ".", else: relative
  end

  defp safe_files(values, limits) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      value = text(value, limits.max_item_bytes)

      if value != "" and Path.type(value) == :relative and value != ".." and
           not String.starts_with?(value, "../") do
        [value]
      else
        []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(limits.max_items)
  end

  defp items(values, limits) do
    values
    |> List.wrap()
    |> Enum.map(&text(&1, limits.max_item_bytes))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(limits.max_items)
  end

  defp normalize_engine("codex"), do: "codex"
  defp normalize_engine(_), do: "claude"

  defp normalize_job_id(id) when is_integer(id) and id >= 0, do: id
  defp normalize_job_id(_), do: nil

  defp normalize_timestamp(value) when is_integer(value) and value > 0, do: value
  defp normalize_timestamp(_), do: now_ms()

  defp optional_text(value, max) when is_binary(value) and value != "", do: text(value, max)
  defp optional_text(_value, _max), do: nil

  defp text(value, max) when is_binary(value), do: truncate_utf8(value, max)
  defp text(value, max) when is_atom(value) or is_number(value), do: text(to_string(value), max)
  defp text(_value, _max), do: ""

  defp truncate_utf8(value, max) when byte_size(value) <= max, do: value

  defp truncate_utf8(value, max) do
    prefix = binary_part(value, 0, max) |> valid_utf8_prefix()
    prefix
  end

  defp valid_utf8_prefix(<<>>), do: ""

  defp valid_utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

  defp maybe_filter(items, _field, nil), do: items
  defp maybe_filter(items, field, value), do: Enum.filter(items, &(Map.get(&1, field) == value))
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now_ms, do: System.system_time(:millisecond)

  # -- Persistence --

  defp persist(%{path: nil}), do: :ok

  defp persist(state) do
    binary =
      :erlang.term_to_binary(%{
        schema_version: @schema_version,
        handoffs: state.handoffs,
        order: state.order,
        generations: state.generations,
        claims: state.claims
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
         {:ok, state} <- load_version(data) do
      state
    else
      false ->
        %__MODULE__{}

      {:error, reason} ->
        Logger.warning("HandoffStore: could not load #{inspect(path)}: #{inspect(reason)}")
        %__MODULE__{load_error: reason}

      _ ->
        %__MODULE__{load_error: :invalid_store}
    end
  end

  defp load_version(%{
         schema_version: @schema_version,
         handoffs: handoffs,
         order: order,
         generations: generations,
         claims: claims
       })
       when is_map(handoffs) and is_list(order) and is_map(generations) and is_map(claims) do
    {:ok,
     %__MODULE__{
       handoffs: handoffs,
       order: order,
       generations: generations,
       claims: claims
     }}
  end

  defp load_version(%{schema_version: version}), do: {:error, {:unsupported_schema, version}}
  defp load_version(_), do: {:error, :missing_schema_version}

  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :unsafe_or_corrupt_term}
  end

  defp configured(key, default),
    do: Application.get_env(:claude_notify, :memory, %{})[key] || default

  defp limit(value, _default) when is_integer(value) and value > 0, do: value
  defp limit(_value, default), do: default

  defp default_path do
    Application.get_env(
      :claude_notify,
      :handoff_store_path,
      Path.join([System.user_home!(), ".claude_notify", "handoffs.dat"])
    )
  end
end
