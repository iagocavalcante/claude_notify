defmodule ClaudeNotify.RouterBodyReader do
  @moduledoc false

  def read_body(conn, opts), do: read_body(conn, opts, "")

  defp read_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw_body = acc <> body
        {:ok, raw_body, Plug.Conn.put_private(conn, :raw_body, raw_body)}

      {:more, body, conn} ->
        read_body(conn, opts, acc <> body)
    end
  end
end
