defmodule ClaudeNotify.MemoryCapture do
  @moduledoc """
  Converts terminal hooks and dispatcher engine events into the narrow
  normalized observation shape accepted by `ClaudeNotify.MemoryStore`.

  Capture is additive: unavailable storage or unresolved project scope never
  breaks notifications or a coding-agent job.
  """

  require Logger

  alias ClaudeNotify.MemoryStore
  alias ClaudeNotify.ProjectScope.Scope

  @terminal_kinds %{
    "session_start" => :session_start,
    "prompt" => :user_prompt,
    "tool_use" => :tool_use,
    "notification" => :notification,
    "stop" => :turn_stop,
    "session_end" => :session_end
  }

  @file_tools ~w(read write edit multi_edit notebook_edit)

  @doc "Captures one terminal hook event using its already-resolved session scope."
  def terminal(params, session) when is_map(params) do
    with true <- enabled?(),
         %Scope{} = scope <- session && session[:project_scope],
         {:ok, kind} <- Map.fetch(@terminal_kinds, params["event"]) do
      {title, body, metadata} = terminal_content(kind, params, scope)

      ingest(%{
        ingest_key: terminal_ingest_key(params, kind, title, body, metadata),
        project_scope: scope,
        source: :terminal,
        engine: params["engine"] || session[:engine],
        session_id: params["session_id"],
        source_event_id: params["event_id"],
        kind: kind,
        title: title,
        body: body,
        metadata: metadata,
        created_at: params["observed_at"]
      })
    else
      false ->
        {:skipped, :disabled}

      nil ->
        warn_unresolved(:terminal, params["session_id"])
        {:skipped, :unresolved_project_scope}

      :error ->
        {:skipped, :unsupported_event}
    end
  end

  @doc "Captures one ordered dispatcher event."
  def dispatcher(%Scope{} = scope, attrs) when is_map(attrs) do
    if enabled?() do
      {title, body, metadata} = dispatcher_content(attrs[:kind], attrs, scope)

      ingest(%{
        ingest_key: "dispatcher:#{attrs[:job_id]}:#{attrs[:sequence]}:#{attrs[:kind]}",
        project_scope: scope,
        source: :dispatcher,
        engine: attrs[:engine],
        session_id: attrs[:session_id] || "job:#{attrs[:job_id]}",
        job_id: attrs[:job_id],
        source_event_id: attrs[:source_event_id],
        sequence: attrs[:sequence],
        kind: attrs[:kind],
        title: title,
        body: body,
        metadata: metadata,
        created_at: attrs[:created_at]
      })
    else
      {:skipped, :disabled}
    end
  end

  def dispatcher(_scope, attrs) do
    if enabled?() do
      warn_unresolved(:dispatcher, is_map(attrs) && attrs[:job_id])
      {:skipped, :unresolved_project_scope}
    else
      {:skipped, :disabled}
    end
  end

  # -- Terminal normalization --

  defp terminal_content(:session_start, params, _scope) do
    {"Session started", "", %{"source" => params["source"] || "startup"}}
  end

  defp terminal_content(:user_prompt, params, _scope) do
    {"User prompt", params["prompt"] || "", %{}}
  end

  defp terminal_content(:tool_use, params, scope) do
    tool = canonical_tool(params["tool_name"])
    paths = extract_safe_paths(tool, params["tool_input"], scope)

    {"Tool: #{tool}", "", %{"tool_family" => tool, "outcome" => "completed", "files" => paths}}
  end

  defp terminal_content(:notification, params, _scope) do
    {"Agent notification", params["message"] || "", %{}}
  end

  defp terminal_content(:turn_stop, params, _scope) do
    {"Turn stopped", params["assistant_response"] || "",
     %{"reason" => params["stop_reason"] || "unknown"}}
  end

  defp terminal_content(:session_end, params, _scope) do
    {"Session ended", "", %{"reason" => params["reason"] || "other"}}
  end

  # -- Dispatcher normalization --

  defp dispatcher_content(:user_prompt, attrs, _scope),
    do: {"Dispatcher prompt", attrs[:body] || "", %{}}

  defp dispatcher_content(:session_start, attrs, _scope),
    do: {"Engine session started", "", %{"engine_session_id" => attrs[:session_id]}}

  defp dispatcher_content(:assistant_text, attrs, _scope),
    do: {"Assistant response", attrs[:body] || "", %{}}

  defp dispatcher_content(:tool_use, attrs, scope) do
    detail = attrs[:detail] || %{}
    tool = canonical_tool(detail[:name])
    paths = extract_safe_paths(tool, detail[:input], scope)

    {"Tool: #{tool}", "", %{"tool_family" => tool, "outcome" => "requested", "files" => paths}}
  end

  defp dispatcher_content(:result, attrs, _scope),
    do: {"Engine result", attrs[:body] || "", %{"status" => attrs[:status] || "unknown"}}

  defp dispatcher_content(kind, attrs, _scope) when kind in [:job_completed, :job_failed] do
    title = if kind == :job_completed, do: "Job completed", else: "Job failed"
    {title, attrs[:body] || "", %{"status" => to_string(attrs[:status] || kind)}}
  end

  defp dispatcher_content(kind, attrs, _scope),
    do: {"Dispatcher event", attrs[:body] || "", %{"kind" => to_string(kind)}}

  # -- Safe tool metadata --

  defp canonical_tool(name) do
    normalized =
      if(is_binary(name) or is_atom(name), do: to_string(name), else: "")
      |> String.trim()
      |> String.downcase()

    cond do
      normalized in ["read", "write", "edit", "multiedit", "multi_edit", "notebookedit"] ->
        normalized
        |> String.replace("multiedit", "multi_edit")
        |> String.replace("notebookedit", "notebook_edit")

      normalized in ["bash", "shell", "exec_command", "command_execution"] ->
        "shell"

      normalized in ["grep", "glob", "search", "list"] ->
        "search"

      normalized in ["task", "agent", "subagent"] ->
        "agent"

      true ->
        "other"
    end
  end

  defp extract_safe_paths(tool, input, scope) when tool in @file_tools do
    input
    |> decode_input()
    |> path_candidates()
    |> Enum.flat_map(fn path ->
      case project_relative_path(path, scope) do
        {:ok, relative} -> [relative]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(file_path_limit())
  end

  defp extract_safe_paths(_tool, _input, _scope), do: []

  defp decode_input(input) when is_map(input), do: input

  defp decode_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_input(_input), do: %{}

  defp path_candidates(input) do
    [input["file_path"], input["path"]]
    |> Enum.concat(List.wrap(input["file_paths"]))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp project_relative_path(path, scope) do
    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, scope.cwd)
      end
      |> physical_path()

    roots = Enum.uniq([scope.worktree_root, scope.repo_root])

    Enum.find_value(roots, :error, fn root ->
      root = root |> Path.expand() |> physical_path()

      if within?(expanded, root) do
        relative = Path.relative_to(expanded, root)

        if relative != "." and not String.starts_with?(relative, "../"),
          do: {:ok, relative}
      end
    end)
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp physical_path(path), do: resolve_physical_path(Path.expand(path), [])

  # Resolve the deepest existing ancestor before appending missing path
  # segments. This catches write targets below an intermediate symlink even
  # when the target file and its immediate parent do not exist yet.
  defp resolve_physical_path(path, suffix) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(path))

        resolve_physical_path(target, suffix)

      _not_a_leaf_symlink ->
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

  defp file_path_limit do
    case Application.get_env(:claude_notify, :memory, %{})[:max_collection_entries] do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> 50
    end
  end

  defp warn_unresolved(source, identifier) do
    safe_identifier =
      identifier
      |> bounded_identifier()
      |> String.replace(~r/[\r\n\t]/u, " ")

    warning_key = {__MODULE__, :unresolved_warning, source, safe_identifier}

    unless Process.get(warning_key) do
      Process.put(warning_key, true)

      Logger.warning(
        "MemoryCapture: #{source} observation skipped: unresolved project scope " <>
          "(source_id=#{safe_identifier})"
      )
    end
  end

  defp bounded_identifier(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp bounded_identifier(value) when is_integer(value), do: Integer.to_string(value)
  defp bounded_identifier(_value), do: "unknown"

  # -- Ingest key and store boundary --

  defp terminal_ingest_key(params, kind, title, body, metadata) do
    case params["event_id"] do
      id when is_binary(id) and id != "" ->
        "terminal:#{params["session_id"]}:#{id}"

      _ ->
        canonical =
          :erlang.term_to_binary({
            params["session_id"],
            kind,
            title,
            body,
            metadata,
            params["observed_at"]
          })

        "terminal-fallback:" <>
          (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
    end
  end

  defp ingest(attrs) do
    case Process.whereis(MemoryStore) do
      nil ->
        {:skipped, :store_unavailable}

      _pid ->
        case MemoryStore.ingest(attrs) do
          {:ok, _status, _observation} = result ->
            result

          {:error, reason} = error ->
            Logger.warning("MemoryCapture: observation skipped: #{inspect(reason)}")
            error
        end
    end
  catch
    :exit, reason ->
      Logger.warning("MemoryCapture: store unavailable: #{inspect(reason)}")
      {:skipped, :store_unavailable}
  end

  defp enabled?, do: Application.get_env(:claude_notify, :memory_capture_enabled, true)
end
