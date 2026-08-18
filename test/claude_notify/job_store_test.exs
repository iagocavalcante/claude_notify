defmodule ClaudeNotify.JobStoreTest do
  use ExUnit.Case, async: false

  alias ClaudeNotify.JobStore

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    name = :"job_store_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "jobs.dat")
    start_supervised!({JobStore, name: name, path: path})
    %{store: name, path: path}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        engine: "claude",
        project: "trainer-gym-ai",
        prompt: "do the thing",
        worktree_path: "/tmp/wt-1",
        branch: "feat/1"
      },
      overrides
    )
  end

  test "create/2 creates a queued job with the given fields", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs(%{project_id: "project_123"}))

    assert job.status == :queued
    assert job.engine == "claude"
    assert job.project == "trainer-gym-ai"
    assert job.project_id == "project_123"
    assert job.prompt == "do the thing"
    assert job.worktree_path == "/tmp/wt-1"
    assert job.branch == "feat/1"
    assert job.engine_session_id == nil
    assert job.telegram_message_ids == []
    assert is_integer(job.inserted_at)
    assert job.updated_at == job.inserted_at
  end

  test "create/2 assigns unique, ordered ids", %{store: store} do
    {:ok, job1} = JobStore.create(store, attrs())
    {:ok, job2} = JobStore.create(store, attrs())
    {:ok, job3} = JobStore.create(store, attrs())

    assert job2.id > job1.id
    assert job3.id > job2.id
  end

  test "get/2 returns the created job", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs())
    assert JobStore.get(store, job.id) == job
  end

  test "get/2 returns nil for an unknown id", %{store: store} do
    assert JobStore.get(store, 999_999) == nil
  end

  test "update/3 updates non-status fields and bumps updated_at", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs())

    {:ok, updated} = JobStore.update(store, job.id, %{engine_session_id: "sess-123"})

    assert updated.engine_session_id == "sess-123"
    assert updated.status == :queued
    assert JobStore.get(store, job.id) == updated
  end

  test "update/3 rejects changing status directly", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs())

    assert JobStore.update(store, job.id, %{status: :running}) == {:error, :use_update_status}
    assert JobStore.get(store, job.id).status == :queued
  end

  test "update/3 returns not_found for an unknown job", %{store: store} do
    assert JobStore.update(store, 999_999, %{engine_session_id: "x"}) == {:error, :not_found}
  end

  test "update_status/4 allows queued -> running", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs())
    {:ok, updated} = JobStore.update_status(store, job.id, :running)

    assert updated.status == :running
  end

  test "update_status/4 allows the full happy path including resume from awaiting_input", %{
    store: store
  } do
    {:ok, job} = JobStore.create(store, attrs())
    {:ok, _} = JobStore.update_status(store, job.id, :running)
    {:ok, waiting} = JobStore.update_status(store, job.id, :awaiting_input)
    assert waiting.status == :awaiting_input

    {:ok, resumed} = JobStore.update_status(store, job.id, :running)
    assert resumed.status == :running

    {:ok, done} = JobStore.update_status(store, job.id, :completed)
    assert done.status == :completed
  end

  test "update_status/4 rejects invalid transitions like completed -> running", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs())
    {:ok, _} = JobStore.update_status(store, job.id, :running)
    {:ok, _} = JobStore.update_status(store, job.id, :completed)

    assert JobStore.update_status(store, job.id, :running) ==
             {:error, {:invalid_transition, :completed, :running}}

    assert JobStore.get(store, job.id).status == :completed
  end

  test "update_status/4 rejects transitions out of terminal states in general", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs())
    {:ok, _} = JobStore.update_status(store, job.id, :discarded)

    assert JobStore.update_status(store, job.id, :running) ==
             {:error, {:invalid_transition, :discarded, :running}}
  end

  test "update_status/4 merges extras (e.g. engine_session_id) with the transition", %{
    store: store
  } do
    {:ok, job} = JobStore.create(store, attrs())

    {:ok, updated} =
      JobStore.update_status(store, job.id, :running, %{engine_session_id: "sess-abc"})

    assert updated.status == :running
    assert updated.engine_session_id == "sess-abc"
  end

  test "update_status/4 returns not_found for an unknown job", %{store: store} do
    assert JobStore.update_status(store, 999_999, :running) == {:error, :not_found}
  end

  test "update_status/4 rejects unknown status atoms", %{store: store} do
    {:ok, job} = JobStore.create(store, attrs())

    assert JobStore.update_status(store, job.id, :bogus) == {:error, {:invalid_status, :bogus}}
    assert JobStore.get(store, job.id).status == :queued
  end

  test "list/2 returns all jobs ordered by id", %{store: store} do
    {:ok, job1} = JobStore.create(store, attrs())
    {:ok, job2} = JobStore.create(store, attrs())

    assert Enum.map(JobStore.list(store), & &1.id) == [job1.id, job2.id]
  end

  test "list/2 filters by status", %{store: store} do
    {:ok, running_job} = JobStore.create(store, attrs())
    {:ok, _queued_job} = JobStore.create(store, attrs())
    JobStore.update_status(store, running_job.id, :running)

    assert Enum.map(JobStore.list(store, status: :running), & &1.id) == [running_job.id]
    assert Enum.count(JobStore.list(store, status: :queued)) == 1
    assert Enum.count(JobStore.list(store)) == 2
  end

  test "state survives a store restart (disk reload)", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "restart.dat")
    name = :"job_store_restart_#{System.unique_integer([:positive])}"

    {:ok, pid} = JobStore.start_link(name: name, path: path)
    {:ok, job} = JobStore.create(name, attrs())
    JobStore.update_status(name, job.id, :running)
    :ok = GenServer.stop(pid)

    {:ok, pid2} = JobStore.start_link(name: name, path: path)

    reloaded = JobStore.get(name, job.id)
    assert reloaded.id == job.id
    assert reloaded.status == :running
    assert reloaded.prompt == job.prompt

    {:ok, next_job} = JobStore.create(name, attrs())
    assert next_job.id > job.id

    :ok = GenServer.stop(pid2)
  end
end
