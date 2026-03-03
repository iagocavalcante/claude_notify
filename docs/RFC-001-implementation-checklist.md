# RFC-001 Implementation Checklist

This checklist tracks execution of `/Users/iagocavalcante/Workspaces/IagoCavalcante/claude_notify/docs/RFC-001-telegram-control-plane.md`.

## Phase 0: Security and Reliability Gate

### Access control and auth

- [ ] Validate inbound Telegram `chat_id` for `message` updates.
- [ ] Validate inbound Telegram `chat_id` for `callback_query` updates.
- [ ] Ignore unauthorized updates and log structured audit event.
- [ ] Add `CLAUDE_NOTIFY_WEBHOOK_SECRET` in runtime config.
- [ ] Verify HMAC signature for `POST /api/events`.
- [ ] Verify request timestamp freshness window (for replay defense).
- [ ] Reject replayed signatures/timestamps.

### Endpoint hardening

- [ ] Gate or remove `/debug/sessions` in non-debug environments.
- [ ] Return explicit 401/403 for auth failures.
- [ ] Return explicit 400 for malformed signed payloads.

### Input/path hardening

- [ ] Sanitize and validate `transcript_path` against allowed roots.
- [ ] Reject traversal and symlink escape attempts.
- [ ] Harden terminal text injection: no direct user text interpolation in AppleScript.

### Reliability

- [ ] Replace unbounded `Task.start` event processing with bounded worker strategy.
- [ ] Configure max concurrent event handlers.
- [ ] Add overload behavior (drop with log or backpressure response).

### Tests (required before exiting Phase 0)

- [ ] Unauthorized Telegram message cannot select/inject into session.
- [ ] Unauthorized Telegram callback cannot trigger response injection.
- [ ] Invalid HMAC on `/api/events` is rejected.
- [ ] Replayed signed request is rejected.
- [ ] Path traversal in `transcript_path` is rejected.
- [ ] Overload path does not crash router/poller.

### Phase 0 exit criteria

- [ ] All tests above pass in CI.
- [ ] Manual smoke test confirms normal flow still works.
- [ ] No known unauthenticated control path remains.

## Phase 1: Session Dashboard

- [ ] Add `ClaudeNotify.Dashboard` GenServer.
- [ ] Implement `/dashboard` command.
- [ ] Pin dashboard message on create.
- [ ] Implement edit coalescing and 5s rate limit.
- [ ] Recreate dashboard if message was deleted.
- [ ] Handle 429 by honoring `retry_after`.
- [ ] Add pagination for long session lists.
- [ ] Display `Last updated` timestamp and stale marker.

### Phase 1 exit criteria

- [ ] Dashboard updates remain stable under rapid session changes.
- [ ] Deleted dashboard auto-recovers without manual intervention.

## Phase 2: Enhanced Prompt Interface

- [ ] Add `ClaudeNotify.ClipboardInjector`.
- [ ] Preserve/restore clipboard around paste injection.
- [ ] Add `/cancel` and `/approve` shortcuts.
- [ ] Auto-select if exactly one active session exists.
- [ ] Reject empty text and non-text messages with clear guidance.
- [ ] Show target session ID in delivery confirmation.
- [ ] Add metadata-only session update API.
- [ ] Ensure `prompt_count` increments only on prompt events.

### Phase 2 exit criteria

- [ ] Multi-line prompt injection works reliably.
- [ ] Session metrics remain accurate during tool/notification traffic.

## Phase 3: Code Change Screenshots

- [ ] Add `ClaudeNotify.DiffCapture`.
- [ ] Add `Telegram.send_photo/2` multipart upload.
- [ ] Render diff image via configured tool.
- [ ] Add text fallback when renderer fails/unavailable.
- [ ] Add temp-file cleanup for success and failure paths.
- [ ] Add per-session/file screenshot rate limiting.

### Phase 3 exit criteria

- [ ] Screenshot path works in happy path.
- [ ] Fallback path works and does not crash pipeline.

## Phase 4: Voice-to-Prompt

- [ ] Add `ClaudeNotify.AudioTranscriber` with configured backend.
- [ ] Add Telegram voice message handling.
- [ ] Send immediate `Transcribing...` status feedback.
- [ ] Add preview with `Send` and `Cancel` actions.
- [ ] Add durable `PendingActionStore` with TTL.
- [ ] Handle expired callbacks with user-facing message.

### Phase 4 exit criteria

- [ ] Restart during pending confirmation does not orphan actions silently.
- [ ] Expired/invalid voice callbacks are safely handled.

## Phase 5: Inline Switching and Polish

- [ ] Add `/switch` command.
- [ ] Add reply-to-message targeting support.
- [ ] Implement compact callback token mapping.
- [ ] Enforce `1..9` direct option keys.
- [ ] Paginate numbered options when count exceeds 9.

### Phase 5 exit criteria

- [ ] Switching is fast and consistent across multiple sessions.
- [ ] No callback payload exceeds Telegram `callback_data` limits.

## Cross-Phase Observability

- [ ] Add structured logs for auth rejects and injection failures.
- [ ] Add metrics for dashboard update success/failure.
- [ ] Add metrics for prompt injection success/failure.
- [ ] Add metrics for voice transcription latency.
- [ ] Add metrics for screenshot render/send latency.
