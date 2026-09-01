defmodule ClaudeNotify.MemoryPages.Page do
  @moduledoc "A human-readable episodic project-memory page."

  @enforce_keys [
    :id,
    :project_id,
    :project_name,
    :source,
    :engine,
    :session_id,
    :summary,
    :decisions,
    :failed_approaches,
    :open_questions,
    :next_steps,
    :files_touched,
    :created_at,
    :path,
    :content
  ]

  defstruct [
    :id,
    :project_id,
    :project_name,
    :source,
    :engine,
    :session_id,
    :job_id,
    :summary,
    :decisions,
    :failed_approaches,
    :open_questions,
    :next_steps,
    :files_touched,
    :created_at,
    :path,
    :content
  ]

  @type t :: %__MODULE__{}
end

defmodule ClaudeNotify.MemoryPages do
  @moduledoc """
  Project-scoped Markdown memory with a rebuildable SQLite FTS5 index.

  Markdown below `projects/<stable-project-id>/` is the source of truth. The
  SQLite database contains only derived search rows and can be dropped and
  rebuilt with `reindex/1`. All filesystem writes use a same-directory
  temporary file followed by an atomic rename.
  """

  use GenServer
  require Logger

  alias ClaudeNotify.HandoffStore
  alias ClaudeNotify.MemoryPages.Page
  alias ClaudeNotify.ProjectScope.Scope
  alias Exqlite.Sqlite3

  @page_schema_version 1
  @default_page_bytes 12_000
  @default_summary_bytes 4_000
  @default_item_bytes 500
  @default_items 20
  @default_results 8
  @default_snippet_bytes 700
  @default_briefing_bytes 6_000
  @safe_segment ~r/^[A-Za-z0-9_-]+$/u

  defstruct [:conn, :root, :database_path, :handoff_store, :limits, :index_error]

  # -- Client API --

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Writes one idempotent episodic Markdown page and indexes it."
  def write_episode(pid \\ __MODULE__, %Scope{} = scope, attrs) when is_map(attrs) do
    GenServer.call(pid, {:write_episode, scope, attrs}, 15_000)
  end

  def recent(pid \\ __MODULE__, project_id, opts \\ []) do
    GenServer.call(pid, {:recent, project_id, opts})
  end

  def search(pid \\ __MODULE__, project_id, query, opts \\ []) do
    GenServer.call(pid, {:search, project_id, query, opts})
  end

  def read(pid \\ __MODULE__, project_id, page_id) do
    GenServer.call(pid, {:read, project_id, page_id})
  end

  def briefing(pid \\ __MODULE__, project_id, opts \\ []) do
    GenServer.call(pid, {:briefing, project_id, opts})
  end

  def status(pid \\ __MODULE__, project_id \\ nil) do
    GenServer.call(pid, {:status, project_id})
  end

  def reindex(pid \\ __MODULE__), do: GenServer.call(pid, :reindex, 30_000)

  # -- Server callbacks --

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, default_root())
    database_path = Keyword.get(opts, :database_path, database_path(root))

    with :ok <- maybe_create_root(root),
         {:ok, conn, index_error} <- open_database(database_path),
         :ok <- create_index(conn) do
      {:ok,
       %__MODULE__{
         conn: conn,
         root: root,
         database_path: database_path,
         handoff_store: Keyword.get(opts, :handoff_store, HandoffStore),
         limits: limits(opts),
         index_error: index_error
       }}
    else
      {:error, reason} -> {:stop, {:memory_pages_init_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}), do: Sqlite3.close(conn)

  @impl true
  def handle_call({:write_episode, scope, attrs}, _from, state) do
    with {:ok, page} <- normalize_page(scope, attrs, state),
         {:ok, status, stored_page} <- persist_page(page, state),
         :ok <- index_page(state.conn, stored_page) do
      {:reply, {:ok, status, stored_page}, %{state | index_error: nil}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recent, project_id, opts}, _from, state) do
    limit = bounded_limit(opts[:limit], state.limits.max_results)

    sql = """
    SELECT page_id, project_id, created_at, source, engine, session_id, path, title
    FROM memory_fts WHERE project_id = ? ORDER BY CAST(created_at AS INTEGER) DESC LIMIT ?
    """

    result =
      with :ok <- validate_segment(project_id),
           {:ok, rows} <- query(state.conn, sql, [project_id, limit]) do
        {:ok, Enum.map(rows, &result_from_recent_row/1)}
      end

    {:reply, result, state}
  end

  def handle_call({:search, project_id, value, opts}, _from, state) do
    limit = bounded_limit(opts[:limit], state.limits.max_results)

    result =
      with :ok <- validate_segment(project_id),
           {:ok, expression} <- fts_expression(value),
           {:ok, rows} <-
             query(
               state.conn,
               """
               SELECT page_id, project_id, created_at, source, engine, session_id, path, title,
                      snippet(memory_fts, 8, '', '', ' … ', 14)
               FROM memory_fts
               WHERE memory_fts MATCH ? AND project_id = ?
               ORDER BY bm25(memory_fts), CAST(created_at AS INTEGER) DESC LIMIT ?
               """,
               [expression, project_id, limit]
             ) do
        {:ok, Enum.map(rows, &result_from_search_row(&1, state.limits.max_snippet_bytes))}
      end

    {:reply, result, state}
  end

  def handle_call({:read, project_id, page_id}, _from, state) do
    result =
      with :ok <- validate_segment(project_id),
           :ok <- validate_segment(page_id),
           {:ok, [[path]]} <-
             query(
               state.conn,
               "SELECT path FROM memory_fts WHERE project_id = ? AND page_id = ? LIMIT 1",
               [project_id, page_id]
             ),
           {:ok, safe_path} <- safe_indexed_path(path, state.root),
           {:ok, page} <- decode_page(safe_path, state.limits.max_page_bytes) do
        {:ok, page}
      else
        {:ok, []} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:briefing, project_id, opts}, _from, state) do
    budget = bounded_budget(opts[:max_bytes], state.limits.max_briefing_bytes)
    {:reply, build_briefing(state, project_id, budget), state}
  end

  def handle_call({:status, project_id}, _from, state) do
    result = memory_status(state, project_id)
    {:reply, result, state}
  end

  def handle_call(:reindex, _from, state) do
    case rebuild_index(state) do
      {:ok, indexed, corrupt} ->
        {:reply, {:ok, %{indexed: indexed, corrupt: corrupt}}, %{state | index_error: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | index_error: reason}}
    end
  end

  # -- Page normalization and Markdown --

  defp normalize_page(scope, attrs, state) do
    with :ok <- validate_segment(scope.id),
         completion_key when is_binary(completion_key) and completion_key != "" <-
           attrs[:completion_key],
         source when source in [:terminal, :dispatcher] <- attrs[:source],
         session_id when is_binary(session_id) and session_id != "" <- attrs[:session_id] do
      digest = hash(Enum.join([scope.id, to_string(source), session_id, completion_key], ":"))
      id = "page_" <> binary_part(digest, 0, 24)
      path = episode_path(state.root, scope.id, id)

      page = %Page{
        id: id,
        project_id: scope.id,
        project_name: bounded(scope.name, 200),
        source: source,
        engine: normalize_engine(attrs[:engine]),
        session_id: bounded(session_id, 200),
        job_id: normalize_job_id(attrs[:job_id]),
        summary: bounded(attrs[:summary], state.limits.max_summary_bytes),
        decisions: bounded_items(attrs[:decisions], state.limits),
        failed_approaches: bounded_items(attrs[:failed_approaches], state.limits),
        open_questions: bounded_items(attrs[:open_questions], state.limits),
        next_steps: bounded_items(attrs[:next_steps], state.limits),
        files_touched: safe_files(attrs[:files_touched], state.limits),
        created_at: normalize_timestamp(attrs[:created_at]),
        path: path,
        content: ""
      }

      content = render_page(page) |> bounded(state.limits.max_page_bytes)
      {:ok, %{page | content: content}}
    else
      _ -> {:error, :invalid_page}
    end
  end

  defp render_page(page) do
    metadata = %{
      "schema_version" => @page_schema_version,
      "id" => page.id,
      "project_id" => page.project_id,
      "project_name" => page.project_name,
      "source" => to_string(page.source),
      "engine" => page.engine,
      "session_id" => page.session_id,
      "job_id" => page.job_id,
      "created_at" => page.created_at
    }

    encoded = metadata |> Jason.encode!() |> Base.url_encode64(padding: false)

    [
      "<!-- claude-notify-page:#{encoded} -->",
      "# #{page_title(page)}",
      "",
      "- Project: #{page.project_name}",
      "- Source: #{page.source} / #{page.engine}",
      "- Session: #{page.session_id}",
      maybe_job_line(page.job_id),
      "- Captured: #{format_timestamp(page.created_at)}",
      "",
      section("Summary", page.summary),
      list_section("Decisions", page.decisions),
      list_section("Failed approaches", page.failed_approaches),
      list_section("Open questions", page.open_questions),
      list_section("Next steps", page.next_steps),
      list_section("Files touched", page.files_touched)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp page_title(%{source: :dispatcher, job_id: id}) when is_integer(id),
    do: "Dispatcher job ##{id} checkpoint"

  defp page_title(_page), do: "Terminal session checkpoint"
  defp maybe_job_line(nil), do: nil
  defp maybe_job_line(id), do: "- Job: ##{id}"
  defp section(_title, ""), do: nil
  defp section(title, body), do: "## #{title}\n\n#{body}\n"
  defp list_section(_title, []), do: nil

  defp list_section(title, items),
    do: "## #{title}\n\n" <> Enum.map_join(items, "\n", &"- #{&1}") <> "\n"

  defp persist_page(%Page{path: nil} = page, _state), do: {:ok, :inserted, page}

  defp persist_page(page, state) do
    with {:ok, path} <- safe_page_path(page.path, state.root),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      if File.regular?(path) do
        case decode_page(path, state.limits.max_page_bytes) do
          {:ok, existing} -> {:ok, :duplicate, existing}
          {:error, reason} -> {:error, {:corrupt_existing_page, reason}}
        end
      else
        temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

        with :ok <- File.write(temporary, page.content),
             :ok <- File.chmod(temporary, 0o600),
             :ok <- File.rename(temporary, path) do
          {:ok, :inserted, %{page | path: path}}
        else
          {:error, reason} ->
            File.rm(temporary)
            {:error, {:page_write_failed, reason}}
        end
      end
    end
  end

  defp decode_page(path, max_bytes) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= max_bytes,
         {:ok, content} <- File.read(path),
         [_, encoded] <- Regex.run(~r/\A<!-- claude-notify-page:([A-Za-z0-9_-]+) -->/u, content),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, metadata} <- Jason.decode(json),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %Page{
         id: metadata["id"],
         project_id: metadata["project_id"],
         project_name: metadata["project_name"],
         source: String.to_existing_atom(metadata["source"]),
         engine: metadata["engine"],
         session_id: metadata["session_id"],
         job_id: metadata["job_id"],
         summary: extract_section(content, "Summary"),
         decisions: extract_list(content, "Decisions"),
         failed_approaches: extract_list(content, "Failed approaches"),
         open_questions: extract_list(content, "Open questions"),
         next_steps: extract_list(content, "Next steps"),
         files_touched: extract_list(content, "Files touched"),
         created_at: metadata["created_at"],
         path: path,
         content: content
       }}
    else
      false -> {:error, :page_too_large}
      nil -> {:error, :missing_metadata}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_page}
    end
  rescue
    ArgumentError -> {:error, :invalid_source}
  end

  defp validate_metadata(%{
         "schema_version" => @page_schema_version,
         "id" => id,
         "project_id" => project_id,
         "project_name" => project_name,
         "source" => source,
         "engine" => engine,
         "session_id" => session_id,
         "created_at" => created_at
       })
       when is_binary(id) and is_binary(project_id) and is_binary(project_name) and
              source in ["terminal", "dispatcher"] and engine in ["claude", "codex"] and
              is_binary(session_id) and is_integer(created_at),
       do: :ok

  defp validate_metadata(%{"schema_version" => version}),
    do: {:error, {:unsupported_page_schema, version}}

  defp validate_metadata(_), do: {:error, :invalid_metadata}

  defp extract_section(content, title) do
    case Regex.run(~r/^## #{Regex.escape(title)}\n\n(.*?)(?=\n## |\z)/msu, content) do
      [_, body] -> String.trim(body)
      _ -> ""
    end
  end

  defp extract_list(content, title) do
    content
    |> extract_section(title)
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "- " <> item -> [item]
      _ -> []
    end)
  end

  # -- SQLite index --

  defp open_database(path) do
    case Sqlite3.open(path || ":memory:") do
      {:ok, conn} ->
        {:ok, conn, nil}

      {:error, reason} when not is_nil(path) ->
        Logger.warning("MemoryPages: index unavailable at #{inspect(path)}: #{inspect(reason)}")

        case Sqlite3.open(":memory:") do
          {:ok, conn} -> {:ok, conn, reason}
          {:error, fallback_reason} -> {:error, fallback_reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_index(conn) do
    Sqlite3.execute(
      conn,
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
        page_id UNINDEXED,
        project_id UNINDEXED,
        created_at UNINDEXED,
        source UNINDEXED,
        engine UNINDEXED,
        session_id UNINDEXED,
        path UNINDEXED,
        title,
        body,
        tokenize = 'unicode61'
      )
      """
    )
  end

  defp index_page(conn, page) do
    with :ok <- execute_prepared(conn, "DELETE FROM memory_fts WHERE page_id = ?", [page.id]),
         :ok <-
           execute_prepared(
             conn,
             """
             INSERT INTO memory_fts
               (page_id, project_id, created_at, source, engine, session_id, path, title, body)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             [
               page.id,
               page.project_id,
               page.created_at,
               to_string(page.source),
               page.engine,
               page.session_id,
               page.path || "",
               page_title(page),
               page.content
             ]
           ) do
      :ok
    end
  end

  defp execute_prepared(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params),
             :done <- Sqlite3.step(conn, statement) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_sql_result, other}}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp query(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params),
             {:ok, rows} <- Sqlite3.fetch_all(conn, statement) do
          {:ok, rows}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp rebuild_index(state) do
    with :ok <- Sqlite3.execute(state.conn, "DROP TABLE IF EXISTS memory_fts"),
         :ok <- create_index(state.conn) do
      state.root
      |> all_episode_paths()
      |> Enum.reduce({0, []}, fn path, {count, corrupt} ->
        with {:ok, page} <- decode_page(path, state.limits.max_page_bytes),
             :ok <- index_page(state.conn, page) do
          {count + 1, corrupt}
        else
          {:error, reason} -> {count, [%{path: path, reason: reason} | corrupt]}
        end
      end)
      |> then(fn {count, corrupt} -> {:ok, count, Enum.reverse(corrupt)} end)
    end
  end

  defp result_from_recent_row([
         id,
         project_id,
         created_at,
         source,
         engine,
         session_id,
         path,
         title
       ]) do
    %{
      page_id: id,
      project_id: project_id,
      created_at: created_at,
      source: source,
      engine: engine,
      session_id: session_id,
      path: path,
      title: title
    }
  end

  defp result_from_search_row(
         [id, project_id, created_at, source, engine, session_id, path, title, snippet],
         max_bytes
       ) do
    result_from_recent_row([id, project_id, created_at, source, engine, session_id, path, title])
    |> Map.put(:snippet, bounded(snippet, max_bytes))
  end

  defp fts_expression(value) when is_binary(value) do
    tokens = Regex.scan(~r/[\p{L}\p{N}_-]+/u, value) |> List.flatten() |> Enum.take(12)

    case tokens do
      [] -> {:error, :empty_query}
      _ -> {:ok, Enum.map_join(tokens, " AND ", &"\"#{String.replace(&1, "\"", "\"\"")}\"")}
    end
  end

  defp fts_expression(_), do: {:error, :empty_query}

  # -- Briefing and status --

  defp build_briefing(state, project_id, budget) do
    with :ok <- validate_segment(project_id),
         {:ok, pages} <- recent_from_state(state, project_id, 3) do
      handoff = newest_open_handoff(state.handoff_store, project_id)
      pinned = pinned_pages(state.root, project_id, budget)

      text =
        [
          "# Project memory briefing",
          render_handoff_brief(handoff),
          render_recent_brief(state, pages),
          render_pinned_brief(pinned)
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      {:ok, truncate_with_notice(text, budget)}
    end
  end

  defp recent_from_state(state, project_id, limit) do
    query(
      state.conn,
      """
      SELECT page_id, project_id, created_at, source, engine, session_id, path, title
      FROM memory_fts WHERE project_id = ? ORDER BY CAST(created_at AS INTEGER) DESC LIMIT ?
      """,
      [project_id, limit]
    )
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &result_from_recent_row/1)}
      error -> error
    end
  end

  defp newest_open_handoff(store, project_id) do
    case HandoffStore.list(store, project_id: project_id, state: :open) do
      handoffs when is_list(handoffs) -> List.last(handoffs)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp render_handoff_brief(nil), do: nil

  defp render_handoff_brief(handoff) do
    lines =
      ["## Open handoff", handoff.summary]
      |> add_brief_items("Open questions", handoff.open_questions)
      |> add_brief_items("Next steps", handoff.next_steps)

    Enum.join(lines, "\n")
  end

  defp render_recent_brief(_state, []), do: nil

  defp render_recent_brief(state, pages) do
    items = Enum.map(pages, &recent_page_brief(state, &1))
    Enum.join(["## Recent episodes" | items], "\n")
  end

  defp recent_page_brief(state, result) do
    detail =
      with {:ok, path} <- safe_indexed_path(result.path, state.root),
           {:ok, page} <- decode_page(path, state.limits.max_page_bytes) do
        [page.summary | Enum.take(page.next_steps, 2)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" Next: ")
      else
        _ -> ""
      end

    suffix = if detail == "", do: "", else: " — #{detail}"
    "- #{result.title} (#{format_timestamp(result.created_at)}, #{result.engine})#{suffix}"
  end

  defp render_pinned_brief([]), do: nil
  defp render_pinned_brief(items), do: Enum.join(["## Pinned project knowledge" | items], "\n\n")

  defp add_brief_items(lines, _label, []), do: lines

  defp add_brief_items(lines, label, items),
    do: lines ++ ["#{label}:", Enum.map_join(items, "\n", &"- #{&1}")]

  defp pinned_pages(nil, _project_id, _budget), do: []

  defp pinned_pages(root, project_id, budget) do
    for filename <- ["rules.md", "architecture.md", "decisions.md"],
        path = Path.join([root, "projects", project_id, filename]),
        File.regular?(path),
        {:ok, content} <- [File.read(path)] do
      "### #{filename}\n#{bounded(content, div(budget, 3))}"
    end
  end

  defp memory_status(state, project_id) do
    with :ok <- validate_optional_segment(project_id),
         {:ok, [[indexed]]} <-
           query(
             state.conn,
             if(project_id,
               do: "SELECT count(*) FROM memory_fts WHERE project_id = ?",
               else: "SELECT count(*) FROM memory_fts"
             ),
             if(project_id, do: [project_id], else: [])
           ),
         {:ok, corrupt_index_rows} <- corrupt_index_rows(state, project_id) do
      {pages, corrupt} = count_source_pages(state, project_id)

      {:ok,
       %{
         source_pages: pages,
         indexed_pages: indexed,
         corrupt_pages: corrupt,
         corrupt_index_rows: corrupt_index_rows,
         healthy?:
           state.index_error == nil and corrupt == [] and corrupt_index_rows == [] and
             pages == indexed,
         index_error: state.index_error
       }}
    end
  end

  defp corrupt_index_rows(state, project_id) do
    sql =
      if project_id,
        do: "SELECT page_id, project_id, path FROM memory_fts WHERE project_id = ?",
        else: "SELECT page_id, project_id, path FROM memory_fts"

    with {:ok, rows} <- query(state.conn, sql, if(project_id, do: [project_id], else: [])) do
      corrupt =
        Enum.flat_map(rows, fn [page_id, indexed_project_id, path] ->
          with {:ok, safe_path} <- safe_indexed_path(path, state.root),
               {:ok, page} <- decode_page(safe_path, state.limits.max_page_bytes),
               true <- page.id == page_id and page.project_id == indexed_project_id do
            []
          else
            error -> [%{page_id: page_id, path: path, reason: index_row_reason(error)}]
          end
        end)

      {:ok, corrupt}
    end
  end

  defp index_row_reason({:error, reason}), do: reason
  defp index_row_reason(false), do: :metadata_mismatch
  defp index_row_reason(other), do: other

  defp count_source_pages(state, project_id) do
    paths =
      case {state.root, project_id} do
        {nil, _} -> []
        {root, nil} -> all_episode_paths(root)
        {root, id} -> project_episode_paths(root, id)
      end

    Enum.reduce(paths, {0, []}, fn path, {count, corrupt} ->
      case decode_page(path, state.limits.max_page_bytes) do
        {:ok, _page} -> {count + 1, corrupt}
        {:error, reason} -> {count, [%{path: path, reason: reason} | corrupt]}
      end
    end)
  end

  # -- Generic helpers --

  defp episode_path(nil, _project_id, _id), do: nil

  defp episode_path(root, project_id, id),
    do: Path.join([root, "projects", project_id, "episodes", id <> ".md"])

  defp safe_page_path(path, root), do: safe_indexed_path(path, root)

  defp safe_indexed_path(path, root) when is_binary(path) and is_binary(root) do
    expanded = physical_path(Path.expand(path))
    root = physical_path(Path.expand(root))

    if expanded == root or String.starts_with?(expanded, root <> "/"),
      do: {:ok, expanded},
      else: {:error, :unsafe_page_path}
  end

  defp safe_indexed_path(_path, _root), do: {:error, :page_unavailable}

  defp physical_path(path), do: resolve_physical_path(path, [])

  defp resolve_physical_path(path, suffix) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(path))

        resolve_physical_path(target, suffix)

      _ ->
        cond do
          File.dir?(path) ->
            append_suffix(physical_directory(path), suffix)

          File.exists?(path) ->
            resolved = Path.join(physical_directory(Path.dirname(path)), Path.basename(path))
            append_suffix(resolved, suffix)

          Path.dirname(path) != path ->
            resolve_physical_path(Path.dirname(path), [Path.basename(path) | suffix])

          true ->
            append_suffix(path, suffix)
        end
    end
  rescue
    _ -> append_suffix(path, suffix)
  end

  defp physical_directory(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> Path.expand(path)
    end
  end

  defp append_suffix(path, []), do: path
  defp append_suffix(path, suffix), do: Path.join([path | suffix])

  defp validate_optional_segment(nil), do: :ok
  defp validate_optional_segment(value), do: validate_segment(value)

  defp validate_segment(value) when is_binary(value) do
    if Regex.match?(@safe_segment, value), do: :ok, else: {:error, :invalid_project_id}
  end

  defp validate_segment(_), do: {:error, :invalid_project_id}

  defp safe_files(values, limits) do
    values
    |> bounded_items(limits)
    |> Enum.filter(
      &(Path.type(&1) == :relative and &1 != ".." and not String.starts_with?(&1, "../"))
    )
    |> Enum.uniq()
  end

  defp bounded_items(values, limits) do
    values
    |> List.wrap()
    |> Enum.map(&bounded(&1, limits.max_item_bytes))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(limits.max_items)
  end

  defp bounded(value, max) when is_binary(value) and byte_size(value) <= max, do: value

  defp bounded(value, max) when is_binary(value),
    do: value |> binary_part(0, max) |> valid_utf8_prefix()

  defp bounded(value, max) when is_atom(value) or is_number(value),
    do: bounded(to_string(value), max)

  defp bounded(_value, _max), do: ""

  defp valid_utf8_prefix(<<>>), do: ""

  defp valid_utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

  defp truncate_with_notice(value, max) when byte_size(value) <= max, do: value

  defp truncate_with_notice(value, max) do
    notice = "\n\n[Project memory truncated to the configured startup budget.]"
    bounded(value, max(max - byte_size(notice), 0)) <> notice
  end

  defp normalize_engine("codex"), do: "codex"
  defp normalize_engine(_), do: "claude"
  defp normalize_job_id(value) when is_integer(value) and value >= 0, do: value
  defp normalize_job_id(_), do: nil
  defp normalize_timestamp(value) when is_integer(value) and value > 0, do: value
  defp normalize_timestamp(_), do: System.system_time(:millisecond)

  defp format_timestamp(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, timestamp} -> DateTime.to_iso8601(timestamp)
      {:error, _reason} -> "unknown time"
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp bounded_limit(value, max) when is_integer(value) and value > 0, do: min(value, max)
  defp bounded_limit(_value, max), do: max

  defp bounded_budget(value, max) when is_integer(value) and value > 0,
    do: min(max(value, 512), max)

  defp bounded_budget(_value, max), do: max

  defp all_episode_paths(nil), do: []

  defp all_episode_paths(root) do
    Path.wildcard(Path.join([root, "projects", "*", "episodes", "*.md"])) |> Enum.sort()
  end

  defp project_episode_paths(root, project_id) do
    Path.wildcard(Path.join([root, "projects", project_id, "episodes", "*.md"])) |> Enum.sort()
  end

  defp maybe_create_root(nil), do: :ok
  defp maybe_create_root(root), do: File.mkdir_p(root)
  defp database_path(nil), do: nil
  defp database_path(root), do: Path.join(root, "memory-index.sqlite3")

  defp limits(opts) do
    config = Application.get_env(:claude_notify, :memory, %{})

    %{
      max_page_bytes:
        limit(opts[:max_page_bytes] || config[:max_page_bytes], @default_page_bytes),
      max_summary_bytes:
        limit(
          opts[:max_summary_bytes] || config[:max_handoff_summary_bytes],
          @default_summary_bytes
        ),
      max_item_bytes:
        limit(opts[:max_item_bytes] || config[:max_handoff_item_bytes], @default_item_bytes),
      max_items: limit(opts[:max_items] || config[:max_handoff_items], @default_items),
      max_results: limit(opts[:max_results] || config[:max_search_results], @default_results),
      max_snippet_bytes:
        limit(
          opts[:max_snippet_bytes] || config[:max_search_snippet_bytes],
          @default_snippet_bytes
        ),
      max_briefing_bytes:
        limit(opts[:max_briefing_bytes] || config[:max_briefing_bytes], @default_briefing_bytes)
    }
  end

  defp limit(value, _default) when is_integer(value) and value > 0, do: value
  defp limit(_value, default), do: default

  defp default_root do
    Application.get_env(
      :claude_notify,
      :memory_pages_root,
      Path.join([System.user_home!(), ".claude_notify", "memory"])
    )
  end
end
