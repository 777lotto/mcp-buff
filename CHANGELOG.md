# Changelog

Notable changes are recorded here. Releases follow semantic versioning.

## Unreleased

### Added

- **Queue navigation inside ticket detail.** `>` and `<` move to the next and
  previous ticket in the current status group, while `<Tab>` and `<S-Tab>`
  cycle through non-empty groups and open each one's newest ticket. Navigation
  performs only a detail read, keeps one float open, and moves the panel cursor
  to the ticket being shown.
- **The Git ticket tab.** `github-broker`'s git write-tickets — the operator
  approval that unlocks `workflows: write` for one push — are now reviewed in
  mcp-buff, with their own state machine, their own
  `zemrip.git-ticket.v1` digest domain, and their own account of what an
  approval does.
- **One panel, one tab per broker.** `:McpBuff` now opens a tabbed review
  surface: each tab holds that broker's ticket queue and its runtime
  permission subset, because everything about one provider shares one
  capability, one loopback socket, and one blast radius. `<Tab>`/`<S-Tab>`
  cycle, `1`/`2` jump, and `:McpBuff <provider>` opens straight to one without
  reading the other broker's capability on the way. The tab bar carries each
  broker's pending count and marks unapplied permission edits, so an inactive
  tab can still ask for attention.
- A ticket-source registry (`lua/mcp_buff/sources/`). A source owns one
  broker's digest domain, state machine, statuses, and request renderers; the
  panel, client, and renderer know only that interface. A third broker is one
  new file plus one configuration key.
- A per-source scope registry with an **exact and total** shape matcher, for
  the further GitHub scopes to come. A broker release that adds a term to a
  request stops matching and falls through to the unrecognised-scope renderer,
  which shows the whole record and says so — rather than describing the ticket
  with the shape it nearly fits. A unit test adds a scope the way a future
  release would and asserts nothing outside the source module has to change.
- A distinct group and warning for a ticket status this release has no entry
  for. It is never folded into `failed` (which would assert the request did
  not happen) or `pending` (which would offer a decision).
- `scripts/stub-git-admin-server.js`, a second dependency-free stub for the
  GitHub admin contract. The smoke test now runs two stubs with two different
  capabilities, so a client that reused one socket's bearer on the other
  cannot pass.
- `pending_count(provider)` for one broker; `pending_count()` now totals every
  broker.
- Optional `tunnel` configuration for a panel-scoped, loopback-only SSH
  forward. McpBuff launches SSH without a shell, waits for its listener before
  reading the admin capability, refuses an already occupied local port, and
  terminates only the process it created.
- Focused lifecycle tests for forward construction, concurrent startup,
  occupied-port refusal, bounded failure, explicit teardown, and unexpected
  SSH exit.

### Changed

- Ticket detail floats now use a plugin-owned display filetype, reset inherited
  scroll offsets, size themselves from wrapped screen rows, wrap long prose at
  word boundaries, and indent continuation lines. Generic Markdown tooling can
  no longer override the review window into horizontal scrolling.
- `bluff` is now the default and only long-lived branch; CI, release
  notification, and contributor guidance no longer retain the retired `bet`
  promotion path.
- Stable releases notify `nvim-config` with the exact tagged commit so its
  tested lock cannot race ahead to a later branch head.
- `canonical.verify()`, `ticket_digest()`, and `ticket_preimage()` now require
  an explicit digest domain and refuse without one. A defaulted domain is the
  cross-broker replay the digest exists to stop: the two brokers hold
  different powers and are reviewed in the same panel, so a shared prefix
  would make a digest typed for a Cloudflare ticket valid for a git ticket
  with an identical immutable payload.
- The decision path now polls until a decision is **settled**, not until the
  ticket is terminal. The git broker's approve unlocks a token rather than
  executing anything, so a successful approval leaves a ticket that is decided
  but still has a transition left; polling for terminal there would sit out
  the whole deadline and then report an unknown outcome for a ticket just
  successfully approved. A `200` carrying a status this release cannot name is
  still resolved by polling.
- `decision_timeout` and `poll_deadline` now default per broker — 1865/1865
  for Cloudflare, whose approval executes a chain of live mutations inside the
  POST, and 120/300 for the GitHub broker, which writes one small file. An
  explicit setting still overrides both.
- Concurrent reads of one capability share a single fetch. A tab reads its
  ticket list and its permission document together, so without coalescing one
  keystroke raised two pinentry prompts for one credential.
- The background timer now refreshes the visible tab only, and can neither
  read a credential nor open an SSH route: a closed managed forward skips the
  tick rather than launching `ssh`.
- `:McpBuffPermissions [provider]` now moves the cursor to that tab's
  permissions section rather than opening a panel of its own, and **the active
  tab is the apply target** — there is nothing to infer from the cursor row.
  `A` applies; `<Space>` and `<CR>` toggle.
- `setup()` gained a `github = { … }` broker key and now rejects an unknown
  top-level option instead of ignoring it. `permissions = { cloudflare, github }`
  is still accepted and mapped rather than reinterpreted:
  `permissions.github` configured that broker's connection, so that is what it
  still configures. Configuring one broker under both spellings is an error
  rather than a merge.
- Closing or hiding the panel now clears every capability and stops every
  managed tunnel. An in-flight approve, deny, or permission update retains
  that broker's route until outcome resolution completes; background refresh
  never reopens a closed managed route.
- Ticket detail buffers are namespaced per provider
  (`mcpbuff://<provider>/ticket/<id>`), and the panel buffer is
  `mcpbuff://review`. Two brokers mint ids from the same pattern, so an
  un-namespaced name could show one broker's ticket under the other's heading.
- **A ticket decision is now one keystroke.** `a` approves and `d` denies with
  nothing to retype. Every check that stands between the keystroke and the
  broker is the panel's own work and is unchanged: the ticket is re-read, its
  status is checked against what that broker can decide, and its digest is
  recomputed locally in that broker's domain and compared with the served one.
  Typing the digest's last eight characters proved none of that — only that the
  digest on screen matched itself — and a confirmation retyped on every ticket
  is one that gets typed without being read. Denial still offers its optional
  note, which is a reason to send back, not a gate. Permission updates still
  require the typed state digest: that write has no operation id to poll, so
  its compare-and-swap ceremony is doing different work.
- **The ticket detail window is a decision surface.** `a`, `d`, `r`, `<CR>`,
  `>`, `<`, `<Tab>`, `<S-Tab>` and `1` … `N` all work inside it — previously
  `a` there began an insert into a read-only buffer — and a decision taken in it
  acts on the ticket it is showing, whatever the panel cursor sits on
  underneath. The permission keys are deliberately absent, because the float
  has no permission rows to act on.
- **One detail window, reused.** Opening another ticket, or deciding the one on
  screen, replaces its contents rather than stacking a float on top of a float,
  so a decision leaves the settled ticket in front of the operator.
- The detail view now carries what the typed prompt used to: the broker's name,
  what approval authorises on that broker, and one line per step naming the
  grant rather than the shape — including a step whose scope this release
  cannot name. It is the last thing read before the decision, so that is where
  the difference between the two brokers' idea of "approve" belongs.

### Removed

- `render.confirm_prompt()` and `render.digest_suffix()`, with the typed
  confirmation they built. Everything they put on screen is now in the detail
  view, which is the surface the decision is taken from.

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

[Unreleased]: https://github.com/777lotto/mcp-buff/commits/bluff
