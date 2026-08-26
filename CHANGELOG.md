# Changelog

Notable changes are recorded here. Releases follow semantic versioning.

## Unreleased

## 2.0.0

Rebuilt against the hardened `mcp-broker` admin contract. This is a breaking
protocol change in both directions: v2 cannot drive a broker release that
predates bearer authentication and digest-bound decisions, and v1 cannot drive
one that requires them.

### Added

- `capability_cmd`, an argv list run with no shell, whose output is sent as
  `Authorization: Bearer` on every admin request. The value is held in Lua
  memory only — never in argv, the environment, on disk, or in a log — for
  `capability_ttl` seconds, and is dropped on panel close, on `VimLeavePre`,
  and on every `setup()`.
- Local recomputation of `ticket_sha256` from the exact broker preimage, with
  a canonical JSON encoder whose test vectors are copied verbatim from the
  broker's own suite. Disagreement, or a payload that cannot be canonicalised
  byte-identically, is a refusal to submit.
- Typed confirmation of the digest's final eight characters before any
  decision.
- Never-resubmit handling: a decision POST that fails, times out, or returns an
  unreadable body is resolved by polling the same ticket to a terminal state
  within `poll_deadline`, then reported as unknown.
- `indeterminate` as its own rendered state, with an explicit note that it is
  an unknown outcome rather than a retry signal.
- Rendering of `expires`, the full `ticket_sha256`, each request's structured
  precondition, and every preflight observation.
- `decision_timeout` and `poll_deadline` options, clamped to `65..86400`
  seconds and sized against the broker's synchronous execution budget.
- `host_header`, for a forward that cannot be made symmetric.
- A stub admin server implementing the hardened contract, so the suite proves
  gate order and precedence, strict schemas, digest binding including
  cross-ticket replay, lazy expiry, retention pruning, HTML off-route bodies,
  and the 32kb-to-`500` behaviour over real curl.

### Changed

- The capability now travels on curl's standard input as a configuration file,
  and the decision body — which is not secret — moved to `--data-raw`
  arguments. This inverts v1's use of standard input.
- `timeout` now applies to reads only and defaults to `30000` ms rather than
  `300000`. Decision POSTs use `decision_timeout`.
- Approve sends `{"ticket_sha256": …}` with `Content-Type: application/json`.
  v1 sent no body at all and was refused at the `415` gate.
- Deny sends `ticket_sha256` alongside its optional note, and renders the
  broker's `denial_note` rather than `note`.
- Gate failures are distinguished by status — `403` Origin, `400` invalid host,
  `401` unauthorized, `415` content type — with their precedence documented. A
  `400` on a decision is treated as a configuration fault, never as retryable.
- The two `409`s are disambiguated by message text.
- Error bodies are decoded defensively: an off-route request returns HTML, and
  a `500` on a decision may be nothing worse than an oversized note.
- The background refresh timer can no longer run `capability_cmd`; a tick with
  a cold or expired cache is skipped instead.
- Panel and detail buffers disable undo files as well as swap files.
- Ticket IDs are validated against the broker's exact 12-hex-suffix shape.
- `setup()` is now required, because `capability_cmd` has no default.

### Removed

- `render.approval()`, replaced by `render.confirm_prompt()` and
  `render.digest_suffix()`. The `&Cancel`/`&Approve` yes/no prompt it fed is
  forbidden by the admin contract.

## 1.0.0

### Added

- Production `bet` as the repository default and an optional focused
  `nvim-config` lock-refresh dispatch after production updates.
- Pending-first, status-grouped `:McpBuff` ticket panel with age and reason
  summaries.
- Full request/result detail rendering, confirm-gated synchronous approval,
  denial notes, manual refresh, optional timer, and cached `pending_count()`.
- Loopback-only curl admin client with no zemRip or Cloudflare credential
  dependency.
- Headless compilation, unit, real-HTTP stub, and vimdoc checks across the same
  Neovim matrix as git-panel.nvim.

[Unreleased]: https://github.com/777lotto/mcp-buff/commits/bet
