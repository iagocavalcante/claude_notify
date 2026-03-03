defmodule ClaudeNotify.PathSafety do
  @moduledoc """
  Helpers for validating file paths from external inputs.
  """

  require Logger

  @doc """
  Returns a sanitized transcript path within configured allowlisted roots, or nil.
  """
  def sanitize_transcript_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, <<0>>) ->
        Logger.warning("PathSafety: rejecting transcript path with null byte")
        nil

      Path.type(trimmed) != :absolute ->
        Logger.warning("PathSafety: rejecting non-absolute transcript path: #{inspect(trimmed)}")
        nil

      true ->
        expanded = Path.expand(trimmed)
        resolved = resolve_path(expanded)

        if allowed_path?(resolved) do
          resolved
        else
          Logger.warning("PathSafety: rejecting transcript path outside allowlist: #{resolved}")
          nil
        end
    end
  end

  def sanitize_transcript_path(_), do: nil

  defp resolve_path(path) do
    case realpath(path) do
      {:ok, real} -> real
      :error -> Path.expand(path)
    end
  end

  # Recursively resolves symlinks to get the real filesystem path.
  # Handles: symlinks at any depth, non-existent leaf files (resolves parent).
  defp realpath(path) do
    case File.read_link(path) do
      {:ok, target} ->
        absolute_target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.join(Path.dirname(path), target)

        realpath(Path.expand(absolute_target))

      {:error, :einval} ->
        # Not a symlink — this component is real
        {:ok, path}

      {:error, :enoent} ->
        # Doesn't exist — resolve parent, keep basename
        parent = Path.dirname(path)

        if parent == path do
          {:ok, path}
        else
          case realpath(parent) do
            {:ok, real_parent} -> {:ok, Path.join(real_parent, Path.basename(path))}
            :error -> :error
          end
        end

      {:error, _} ->
        :error
    end
  end

  defp allowed_path?(path) do
    roots = Application.get_env(:claude_notify, :transcript_allowed_roots, ["/tmp"])

    Enum.any?(roots, fn root ->
      expanded_root = Path.expand(root)
      path == expanded_root or String.starts_with?(path, expanded_root <> "/")
    end)
  end
end
