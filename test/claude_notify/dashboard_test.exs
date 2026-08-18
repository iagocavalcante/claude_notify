defmodule ClaudeNotify.DashboardTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.{Dashboard, JobStore}

  @now 1_800_000_000

  test "lists active Codex and Claude Code jobs alongside terminal sessions" do
    jobs = [
      job(12, "codex", "api", :running, "Fix the API tests"),
      job(13, "claude", "web", :queued, "Improve the settings page"),
      job(11, "claude", "done", :completed, "This must not appear")
    ]

    sessions = [
      {"session-123456789",
       %{
         working_dir: "/Users/me/Workspaces/mobile",
         status: :waiting_input,
         started_at: @now - 180,
         last_activity: @now - 5,
         prompt_count: 3,
         last_tool: "Edit"
       }},
      {"idle-session-987654",
       %{
         working_dir: "/Users/me/Workspaces/backend",
         engine: "codex",
         status: :idle,
         started_at: @now - 3_600,
         last_activity: @now - 30,
         prompt_count: 8,
         last_tool: "Bash"
       }}
    ]

    {text, keyboard} = Dashboard.build_dashboard_content(sessions, jobs, @now)

    assert text =~ "Agent Dashboard"
    assert text =~ "2 agent jobs"
    assert text =~ "2 terminal sessions"
    assert text =~ "Codex"
    assert text =~ "Claude Code"
    assert text =~ "api"
    assert text =~ "web"
    assert text =~ "mobile"
    assert text =~ "backend"
    assert text =~ "working"
    assert text =~ "queued"
    assert text =~ "waiting for input"
    assert text =~ "idle"
    refute text =~ "This must not appear"

    callback_data = keyboard |> List.flatten() |> Enum.map(& &1.callback_data)
    assert "jobwatch:12" in callback_data
    assert "jobwatch:13" in callback_data
    assert "select:session-123456789" in callback_data
    assert "select:idle-session-987654" in callback_data
    assert "nav:new" in callback_data
    assert "dash:refresh" in callback_data
  end

  test "empty dashboard explains what to do next" do
    {text, keyboard} = Dashboard.build_dashboard_content([], [], @now)

    assert text =~ "Nothing is running"
    assert text =~ "/new"
    assert get_in(keyboard, [Access.at(0), Access.at(0), :callback_data]) == "nav:new"
  end

  test "lists active OTP-protected previews with direct URL buttons" do
    previews = [
      %{
        id: 4,
        job_id: 12,
        project: "web",
        url: "https://preview-12-a1b2c3.example.com",
        expires_at: @now + 3_600
      }
    ]

    {text, keyboard} = Dashboard.build_dashboard_content([], [], previews, @now)

    assert text =~ "1 web preview"
    assert text =~ "Web previews"
    assert text =~ "Preview \\#4"
    assert text =~ "1h 0m left"

    assert Enum.any?(List.flatten(keyboard), fn button ->
             button[:url] == "https://preview-12-a1b2c3.example.com"
           end)
  end

  defp job(id, engine, project, status, prompt) do
    %JobStore.Job{
      id: id,
      engine: engine,
      project: project,
      status: status,
      prompt: prompt,
      inserted_at: @now - id * 10,
      updated_at: @now - id
    }
  end
end
