# mcp-buff

[![CI](https://github.com/777lotto/mcp-buff/actions/workflows/ci.yml/badge.svg?branch=bet)](https://github.com/777lotto/mcp-buff/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io/)
[![Release](https://img.shields.io/github/v/release/777lotto/mcp-buff)](https://github.com/777lotto/mcp-buff/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A dependency-free Neovim review panel for broker write tickets and broker
runtime permissions. One panel, one tab per broker: **Cloudflare** reviews
Cloudflare mutations, **Git** reviews the GitHub broker's git write-tickets —
the operator approval that unlocks `workflows: write` for one push. Each tab
also carries that broker's runtime permission subset. Every route is a
loopback-only admin API reached over SSH.

## Highlights

- One tab per broker, each holding that broker's ticket queue and its runtime
  permissions. Everything about one provider shares one capability, one
  loopback socket, and one blast radius, so it shares one tab.
- Pending-first ticket lists grouped by **that broker's own** statuses:
  Cloudflare's `indeterminate` is its own state rather than a kind of failure,
  and the GitHub broker's approved-but-unspent grant is its own state rather
  than finished work.
- A status a release has never heard of gets its own bucket and its own
  warning. It is never folded into a status that happens to be nearby.
- Markdown detail view with the full reason, the expiry, the complete
  `ticket_sha256`, what approval actually authorises, and every reviewable term
  of every stored request.
- Separate digest domains per broker, so a digest reviewed for one provider can
  never authorise the other.
- A request shape a release does not recognise is shown in full and labelled as
  unrecognised, never described as the shape it nearly matches.
- Each broker has its own admin capability, fetched from a command you supply
  and kept in memory only — never in argv, the environment, on disk, or in a
  log. Concurrent reads share one fetch, so one keystroke never raises two
  credential prompts.
- `ticket_sha256` is recomputed locally, in that broker's domain, and
  disagreement is a hard refusal.
- Typed digest confirmation that says which broker and what the approval does.
  No single-keypress approval, no yes/no prompt.
- A decision is never resubmitted: an unaccounted-for POST is resolved by
  polling the same ticket.
- Cached `pending_count()` across brokers for statusline integrations.
- Manual refresh plus an optional timer that is off by default and can neither
  raise a credential prompt nor open an SSH route.
- Compare-and-swap permission updates with typed state-digest confirmation.
- No Neovim plugin dependencies and no provider credential handling.

## Requirements

- Neovim 0.10 or newer
- `curl` available on `PATH`
- SSH access to an installed broker admin listener, or an existing local
  forward to it (`8792` for Cloudflare and `8793` for GitHub)
- a command that prints each broker's admin capability, such as a `pass` entry

The GitHub broker's review plane is optional and off by default on the host. A
tab whose broker has no `capability_cmd` says what is missing rather than
disappearing.

The plugin deliberately accepts only endpoints in the form
`http://127.0.0.1:PORT`. It never connects to the Incus bridge, the container,
or Cloudflare directly.

## Installation

With lazy.nvim, matching the `nvim-config` GitPanel pattern:

```lua
{
  "777lotto/mcp-buff",
  main = "mcp_buff",
  cmd = { "McpBuff", "McpBuffPermissions" },
  keys = {
    { "<leader>mb", "<cmd>McpBuff<cr>", desc = "Broker write tickets" },
    { "<leader>mp", "<cmd>McpBuffPermissions<cr>", desc = "Broker permissions" },
  },
  opts = {
    -- The unprefixed keys configure the Cloudflare broker.
    endpoint = "http://127.0.0.1:8792",
    capability_cmd = { "pass", "show", "your/broker/admin-capability" },
    tunnel = {
      host = "your-broker-host",
    },
    -- The GitHub broker: one connection, serving its tickets and its
    -- permissions both.
    github = {
      endpoint = "http://127.0.0.1:8793",
      capability_cmd = { "pass", "show", "your/github/admin-capability" },
      tunnel = { host = "your-broker-host" },
    },
  },
}
```

`setup()` must be called, because `capability_cmd` has no default.

With Neovim's native packages:

```sh
git clone https://github.com/777lotto/mcp-buff \
  ~/.local/share/nvim/site/pack/plugins/start/mcp-buff
nvim --headless -c "helptags ALL" -c quit
```

## Approval tunnel

Each broker admin API binds only to box loopback. McpBuff can own the local
forward for the lifetime of the review panel, per broker — a tunnel is never
inherited between them, because two brokers reachable through one SSH alias
still need two forwards to two ports:

```lua
tunnel = {
  host = "your-broker-host", -- SSH alias or hostname
  ssh_command = "ssh",
  startup_timeout = 30000,   -- milliseconds
}
```

With this option, the first visit to that broker's tab launches one foreground
SSH process with no shell:

```text
ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -o ControlMaster=no -o ControlPath=none \
  -L 127.0.0.1:8792:127.0.0.1:8792 your-broker-host
```

McpBuff waits for the listener before reading the capability or making an HTTP
request. Closing the panel with `q`, `:close`, or a window-manager mapping
terminates only that SSH child; `VimLeavePre` does the same. An in-flight
approve or deny keeps the route until its outcome is resolved, even if the
panel is hidden, and then closes it. McpBuff never starts, stops, or
reconfigures an underlying VPN.

Managed mode refuses to reuse an already occupied local port. That fail-closed
rule prevents the capability from being sent through a process McpBuff did not
create. Use a dedicated SSH alias without unrelated configured forwards.

A forward opens when the operator visits that broker's tab, and only then.
Opening the panel does not reach a broker whose tab you have not selected.

The default, `tunnel = false`, preserves external lifecycle management. In
that mode, open the forward before starting the panel:

```sh
ssh -N -L 8792:127.0.0.1:8792 you@your-broker-host
```

**The forward must be symmetric, or you must override `Host`.** The broker
compares the request `Host` against its own bound socket port, not against a
port you choose. `-L 8792:127.0.0.1:8792` works; `-L 9999:127.0.0.1:8792`
satisfies every condition stated in prose — dotted-quad loopback, explicit
port — and is still rejected with `400`, because the client sends
`Host: 127.0.0.1:9999` while the broker's bound port is `8792`. Either make the
local forward port equal the broker's admin port, or set `host_header`.

Keep an externally managed SSH process running while reviewing. Stopping it
revokes reachability. Never add `-g` or bind the local side to `0.0.0.0`.

## The admin capability

Every admin request carries `Authorization: Bearer <capability>`, 64 lowercase
hex characters. `capability_cmd` is an argv list, run with **no shell**:

```lua
capability_cmd = { "pass", "show", "your/broker/admin-capability" }
```

The command must print the capability and nothing else. mcp-buff keeps the
value in Lua memory only: it never reaches argv, an environment variable, disk,
or any message the plugin prints. It travels to curl through a configuration
file fed on standard input.

The value is held for `capability_ttl` seconds so that refreshing does not
re-run the command for every request, and is dropped when the review session
closes, when Neovim exits, and whenever `setup()` runs again. An in-flight
decision or permission update delays that broker's teardown until its outcome
resolves. A `401` triggers exactly one forced re-read, in case the capability
was rotated mid-session; after that the failure is surfaced rather than retried.

Concurrent reads of one capability share a single fetch. A tab reads its ticket
list and its permission document at the same moment and both need the same
bearer, so without coalescing one keystroke would run `capability_cmd` twice
and raise two pinentry prompts for one credential.

A failed capability read **aborts the request**. mcp-buff never falls back to
an unauthenticated send, because that failure reaches you as an opaque `401`
rather than as "your card is not available".

The background refresh timer never runs `capability_cmd` and never opens a
forward. If the cached value has expired, or the managed route is closed, the
tick is skipped instead — a credential prompt storm and a timer-opened SSH
route are both structurally impossible, not merely unlikely. Press `r` to
acquire one again.

**Two brokers never share a bearer value.** Each has its own `capability_cmd`,
its own in-memory cache object, its own endpoint, and its own optional managed
tunnel. The isolation is structural: they are separate cache instances, not
separate call sites that are careful.

## The two tabs

`:McpBuff` opens one panel with a tab per configured broker. `<Tab>` and
`<S-Tab>` cycle; `1` and `2` jump; `:McpBuff cloudflare` and `:McpBuff github`
open straight to one. The tab bar carries each broker's pending ticket count
and a `*` when that tab has unapplied permission edits, so a tab you are not
looking at can still ask for attention.

```text
  MCP Buff · Broker Review
  ▸ 1 Cloudflare 2    2 Git 3
```

Only the visible tab is read. Switching to a tab for the first time is what
reads its capability and opens its forward; returning to it renders what is
already held, so cycling tabs never re-prompts. `r` forces a re-read of the
visible tab.

### Cloudflare

Cloudflare has no native proposal object for a DNS or Worker mutation, so its
broker manufactures one per mutation and **executes it inside the approval
POST**. Approval is therefore terminal, the interesting evidence is the
preflight observation and the result, and `indeterminate` is a first-class
state: a mutation that may or may not have reached Cloudflare is neither a
success nor a failure.

### Git

GitHub needs far fewer tickets, because pull requests already provide a diff
and a review surface. What it does need a ticket for is the small set of scopes
that reach past that surface. Today there is one: a push that changes
`.github/workflows/**`. A push to an agent branch runs Actions on that branch
before any pull request is read, so `workflows: write` is gated on a human
decision rather than on the ref filter that guards every other push.

**Approval here executes nothing.** It unlocks a token that a later push, on a
different connection, may spend — or may never spend. Three consequences are
visible in the panel:

- `approved` is not terminal. An approved, unspent ticket is an outstanding
  grant, listed as `Approved · unspent` directly under `Pending`, and its
  detail says the grant is still open.
- A successful approve returns `approved`, and that **is** the answer. The
  client does not then poll for a terminal state it may never reach.
- `Spent` records that the grant was claimed, not that the push reached GitHub.
  A push that fails at GitHub still burns its approval. GitHub's own log is the
  record of what landed.

A ticket licenses **one** push, of **exactly** the ref set it names, to one
repository. The ref set is the grant, so every ref is rendered — never a count
and an ellipsis.

The GitHub broker's review plane is optional on the host. Without it the broker
starts with the surface absent and refuses every workflow push.

### More GitHub scopes

More GitHub scopes are expected, and the panel is built for them. Each source
module owns a scope registry, and one entry is a shape, a one-line summary, and
a renderer:

```lua
-- lua/mcp_buff/sources/github.lua
M.scopes = {
  {
    id = 'workflow-push',
    title = 'Workflow-changing push',
    matches = function(request)
      return registry.shape(request, { repo = 'string', refs = 'string[]' })
    end,
    summary = function(request)
      return ('%s · %d refs'):format(request.repo, #request.refs)
    end,
    render = function(lines, request) ... end,
  },
}
```

Nothing outside that file changes. The panel, the client, and the renderer
never learn a scope's name.

**The shape match is exact and total**, and that direction is the safety
property. Every declared key must be present with the declared type, and no key
beyond the declaration may appear. So when a broker release adds a term to a
request, the shape stops matching and the request falls through to the
unrecognised-scope renderer, which shows the whole record and says the panel
cannot describe it. A tolerant match would instead render the new term's ticket
under the old shape's description — and the operator would approve a grant
whose extra term was never on screen. Failing to recognise a request is
recoverable; describing it wrongly is not.

An unrecognised scope is still decidable. Its digest still verifies and its
whole record is still shown, and refusing would leave you with no review
surface at all for a broker newer than the panel. The confirmation prompt names
it as unrecognised, at the keystroke.

## Runtime permissions

Each tab carries its broker's runtime permission subset below its ticket queue.
These are effective runtime switches below the reviewed release's compiled
policy:

- GitHub groups cover MCP, Git read, agent-branch push, reviewed workflow push,
  API reads, issue writes, pull-request writes, and gated merge.
- Cloudflare entries correspond one-for-one with the broker's compiled mutation
  operation IDs.

This is the effective authorization intersection:

```text
upstream credential ceiling
  ∩ compiled broker registry and route policy
  ∩ persisted runtime enabled set
  = operation that can execute
```

The panel can remove IDs only from the innermost term. It cannot add an
operation, change a route, edit credentials, alter the GitHub App installation,
or expand a Cloudflare API token. On first use a broker exposes its compiled
permissions as enabled; subsequent narrowing is persisted by that broker on the
host.

Toggle entries with `<Space>` or `<CR>`, then press `A`. **The active tab is the
apply target** — there is nothing to infer from the cursor row. Applying
requires the final eight characters of the state digest the panel displays. The
complete current digest is sent with the desired enabled IDs, so a concurrent
change is rejected with `409` and must be refreshed.

Unlike a ticket decision, a permission update has no operation ID to poll after
an interrupted POST. A network failure, timeout, or undecodable body is
therefore reported as **outcome unknown** and never retried, because the first
write may have committed. A fresh read is the only recovery.

Set `permissions = false` on a broker to hide its section, or the broker itself
to `false` to drop its tab entirely. Older broker releases without
`GET /permissions` and `POST /permissions` report the route as unavailable;
upgrade the broker rather than weakening its admin boundary.

## Configuration

```lua
require("mcp_buff").setup({
  -- The unprefixed keys configure the Cloudflare broker. They predate the
  -- second provider and are kept as they were.
  endpoint = "http://127.0.0.1:8792",
  capability_cmd = nil,     -- required; argv list, run with no shell
  host_header = nil,        -- e.g. "127.0.0.1:8792" for an asymmetric forward
  tunnel = false,           -- or { host = "broker-ssh-alias" }

  -- The GitHub broker: one connection, serving its tickets and its permissions.
  github = {
    endpoint = "http://127.0.0.1:8793",
    capability_cmd = nil,   -- a separate GitHub admin capability
    host_header = nil,
    tunnel = false,         -- never inherited; two brokers need two forwards
    permissions = true,     -- false hides this tab's permissions section
  },

  -- Inherited by any broker that sets none of its own.
  curl_command = "curl",
  capability_ttl = 300,     -- seconds each capability is held in memory
  timeout = 30000,          -- milliseconds; reads only
  decision_timeout = nil,   -- seconds; per-broker default when unset
  poll_deadline = nil,      -- seconds; per-broker default when unset

  -- Panel-wide.
  refresh_interval = 0,     -- seconds; 0 keeps automatic refresh off
})
```

Set `cloudflare = { ... }` instead of the unprefixed keys if you prefer both
brokers named; configuring one broker both ways is an error rather than a
merge, because there is no way to tell which endpoint was meant. Set either
provider to `false` to drop its tab. An unknown top-level key is rejected: a
silently ignored typo in a security surface is how an endpoint ends up
somewhere nobody intended.

`permissions = { cloudflare = …, github = … }` is the previous spelling, from
when the permissions panel was the only place a second broker appeared. It is
still accepted and mapped, not reinterpreted: `permissions.github` configured
that broker's connection, so that is what it still configures.

`setup()` rejects remote, bridge, HTTPS, path-bearing, and credential-bearing
endpoints. Curl ignores user configuration and does not follow redirects.
When `tunnel` is enabled, `host` is required; `ssh_command` defaults to `ssh`,
and `startup_timeout` accepts `1000..120000` milliseconds. Unknown tunnel keys
are rejected.

**The read and decision timeouts are different budgets and are deliberately not
shared.** `timeout` covers reads, which perform no execution — a read that hangs
for half an hour is a broken tunnel, not a long approval.

`decision_timeout` covers the approve and deny POST, and its sensible value is a
property of the broker rather than of the panel, so each source supplies its
own default:

- **Cloudflare, `1865`.** The broker performs every preflight GET and every
  mutation inside the POST: up to ten requests, each with two preflight GETs
  and a mutation, each individually timed at the broker's own 60s default. The
  worst case is far longer than a conventional HTTP timeout.
- **Git, `120`.** Nothing executes inside the POST. The broker writes one small
  file and renames it.

Setting `decision_timeout` or `poll_deadline` explicitly overrides both. Both
are clamped to `65..86400`.

Neither timeout bounds your review time. That is bounded only by the ticket's
expiry, which the detail view always shows.

Set `refresh_interval` to a positive whole number to refresh in the background.
Manual `r` remains available regardless. The default is intentionally off so
merely installing the plugin creates no recurring network activity. In managed
mode, timer ticks occur only while the panel is visible and never reopen a
closed tunnel.

## Commands and controls

- `:McpBuff` opens the review panel as a left split, on the active tab.
- `:McpBuff cloudflare` / `:McpBuff github` open straight to one tab, without
  reading the other broker's capability on the way.
- `:McpBuffPermissions [provider]` opens the panel with the cursor on that
  tab's permissions section.

Mappings are local to the panel buffer:

| Key       | Action                                                                         |
| --------- | ------------------------------------------------------------------------------ |
| `<Tab>`   | Next broker tab                                                                |
| `<S-Tab>` | Previous broker tab                                                            |
| `1` … `N` | Jump to a broker tab                                                           |
| `<CR>`    | On a ticket, fetch and open it in full; on a permission, toggle it locally     |
| `a`       | Re-fetch, review, type the digest confirmation, and approve                    |
| `d`       | Re-fetch, review, type the digest confirmation, and deny with an optional note |
| `<Space>` | Toggle a runtime permission locally                                            |
| `A`       | Apply this tab's permission changes after typed state-digest confirmation      |
| `r`       | Refresh this tab                                                               |
| `q`       | Close the panel and every managed tunnel                                       |

`<NL>` and keypad Enter work like `<CR>`, matching terminal-safe GitPanel
behavior. Detail windows close with `q` or `<Esc>`.

Closing the panel during an in-flight decision or permission update keeps that
broker's owned route alive until the result is accounted for, then closes it.

## Review behavior

Each tab renders its own broker's statuses, pending first:

| Cloudflare      | Git                  |
| --------------- | -------------------- |
| `pending`       | `pending`            |
| `approved`      | `approved` (unspent) |
| `executing`     | `consumed` (spent)   |
| `indeterminate` | `denied`             |
| `failed`        | `expired`            |
| `denied`        |                      |
| `expired`       |                      |
| `executed`      |                      |

A status the broker served that the release has no entry for is collected in
its own bucket, with a warning that it is neither decidable nor known to be
finished. Folding it into `failed` would assert the request definitely did not
happen; folding it into `pending` would offer a decision. Both are claims about
a word the client does not know.

A decision does not trust the cached list row. Pressing `a` or `d` re-fetches
the full ticket, refuses anything that broker cannot decide, and renders the
reason, the expiry, the complete digest, what approval authorises, and every
reviewable term of every stored request — for Cloudflare that is each method,
literal path, pretty-printed body, structured precondition, and preflight
observation; for Git it is the repository and every ref in the set.

### Digest recomputation, and two digest domains

The digest covers exactly `id`, `created`, `expires`, `reason` and `requests` —
the same five immutable fields on both brokers. Only the domain prefix differs:

```text
sha256("zemrip.mcp-ticket.v1" + "\n" + canonicalJson(payload))   # Cloudflare
sha256("zemrip.git-ticket.v1" + "\n" + canonicalJson(payload))   # Git
```

**That difference is load-bearing, not cosmetic.** The two brokers hold
different powers and are reviewed in the same panel. A shared prefix would make
a digest the operator typed for a Cloudflare ticket a valid digest for a git
ticket carrying an identical immutable payload — exactly the cross-ticket replay
the digest exists to stop. Different power, different domain separator. Nothing
in mcp-buff defaults the domain: a verification called without one refuses
rather than picking.

mcp-buff recomputes the digest locally, in the domain of the broker whose tab
the ticket is on, and refuses to submit when the result disagrees with the
served value. It also refuses when the payload contains anything it cannot
canonicalise to the same bytes the broker would produce — in practice a
non-integer number or a non-ASCII object key. Refusing is deliberate: a guessed
digest would let you approve a payload you had not actually verified.

The digest catches a cross-ticket replay, a cross-broker replay, a client-side
digest bug, and direct tampering with the stored ticket. It does **not** detect
a concurrent decision: the five immutable fields never change, so a ticket
approved, denied, or expired between your read and your submission keeps an
identical digest. That race is caught by the ticket state machine instead.

### Typed confirmation

After the render, mcp-buff requires you to type the final eight characters of
the digest. The prompt also names the broker and says what the decision
authorises, because the two mean different things by the word "approve", and one
line per step names its scope:

```text
GitHub broker · t_20260903T090000.000Z_0000000000b1
ticket_sha256: fb00f5ea…ab87116d
This approve authorises no immediate action. It unlocks that scope for one
later push, which is spent before a byte is forwarded and cannot be reused.
  step 0 · Workflow-changing push · 777lotto/zemrip · 1 ref
Type the final digest bytes ab87116d to approve:
```

There is no single-keypress approval and no yes/no prompt. Anything other than
the exact suffix cancels and nothing is sent.

### Outcomes

A decision is **never resubmitted**. Resubmitting cannot execute a ticket twice
— neither state machine has an edge back to `pending` — but the resulting `409`
destroys the account of what happened: it has the same shape as an expiry and a
decision made elsewhere, and tells you only where the ticket stands now, not
what your first submission did.

So when a decision POST fails, times out, or returns a body mcp-buff cannot
read, it polls that same ticket every two seconds until the decision **settles**,
up to `poll_deadline`. On the deadline, or if the ticket cannot be fetched at
all, it reports the outcome as unknown and stops. When the broker refuses
outright — a gate failure, a `404`, a `413`, or either `409` — nothing was
touched, so the refusal is reported directly and nothing is polled.

**Settled is not the same as terminal**, and the difference is why each broker
declares both:

- Cloudflare's approval executes synchronously inside the POST, so a `200` from
  approve is always terminal, and settled and terminal are the same set.
  `indeterminate` means the outcome is genuinely unknown: a mutation may or may
  not have reached Cloudflare. It is rendered as its own state, never as a
  failure, and it is not a retry signal.
- The Git broker's approval only unlocks a token, so a successful approve leaves
  the ticket `approved` — settled, because the decision landed, but not
  terminal, because the push it licenses has not happened. A client that polled
  for a terminal state here would sit out its whole deadline on a decision that
  succeeded immediately, and then report an unknown outcome for a ticket it had
  just approved.

A `200` carrying a status the release has never heard of is not an answer
either way, so it is resolved by polling. A client that cannot name a status
cannot claim to know what it means.

### Errors you will see

The four transport gates have distinct statuses and share one ordered
middleware chain on both brokers: Origin (`403`), Host (`400`), bearer (`401`),
then content type (`415`) on POSTs only. A status names the _first_ gate that
failed, not the worst thing wrong with the request, so a bad `Host` masks a
missing capability and answers `400` rather than `401`. Fix them in that order.

- `400 {"error":"invalid host"}` is a configuration fault — an asymmetric
  forward. It is never a retryable body error and must not prompt a resubmit.
  The remedy names that broker's own port.
- Both `409`s share a status and are separated only by message text: a digest
  mismatch, or a state transition that is no longer legal — which after a
  pending render means the ticket expired or was decided while you reviewed.
- A terminal ticket is unlinked once past the broker's retention window and
  then `404`s. Listing tickets is what expires the overdue and prunes the aged,
  on both brokers, so a list is not a pure read.

Three wire facts genuinely differ between the two brokers. They are carried by
each source rather than branched on, so a message is accurate for the broker
that actually answered:

- **A body over the 32kb cap.** Cloudflare answers `500`, an unknown outcome
  that is polled — a defect that release documents. The GitHub broker answers
  `413`, which is definitive: nothing was decided.
- **An off-route request.** Cloudflare returns **HTML**, from Express's
  finalhandler. The GitHub broker returns JSON, from its admin handler's own
  `404`.
- **A refused digest.** On Cloudflare, no Cloudflare request was sent. On the
  GitHub broker, no token was minted and no push is licensed.

Error bodies are decoded defensively on both, because "every non-2xx carries
`{"error":…}`" is true of neither.

## Statusline API

`pending_count()` is intentionally nonblocking and returns the latest cached
count **across every broker**, which is what a statusline wants: whether work
is waiting does not depend on which tab happens to be open. Pass a provider id
for one of them. It is `0` before the first successful refresh, and a tab you
have never visited contributes `0`.

```lua
function()
  local mcp = require("mcp_buff")
  local total = mcp.pending_count()
  if total == 0 then return "" end
  return ("broker: %d (cf %d / git %d)"):format(
    total, mcp.pending_count("cloudflare"), mcp.pending_count("github"))
end
```

With an external tunnel, the optional timer can keep the statusline current
while the panel is closed. Managed mode is intentionally panel-scoped, so its
timer neither reopens a closed route nor visits a tab you are not on.

## Security boundary

McpBuff speaks only the broker admin APIs. It has no dependency on zemRip, no
GitHub or Cloudflare API client, and no place to configure a provider token.

- every endpoint is syntactically restricted to IPv4 loopback, per broker;
- the capability is the only secret, and it travels on the private channel — a
  curl configuration file on standard input, never argv, the environment, disk,
  or a log. It is validated and used, never republished on the public config
  table;
- each broker owns a separate capability cache object, so one broker's bearer
  cannot reach the other's socket. Nothing is inherited between brokers except
  values that identify neither: the curl binary, the timeouts, and the TTL;
- the decision body is not secret and travels through ordinary process
  arguments. Process arguments are visible to other processes running as your
  user, so do not type anything into a denial note you would not put in `ps`
  output;
- curl user configuration and redirects are disabled, and no shell is involved
  anywhere, including the capability fetch and managed SSH launch;
- managed mode uses a symmetric loopback-only forward, disables SSH control
  multiplexing for exact process ownership, and refuses an existing listener;
- approve and deny operate only on a broker-shaped ticket ID and send only what
  the strict schemas allow;
- approve and deny send only the digest of the ticket the broker already
  stored, so no plugin or user input can replace the stored requests;
- permission updates carry only a state digest and a subset of IDs advertised
  by that same provider, bound to the socket it was read from;
- a request shape the release cannot name is shown in full and labelled, never
  described as a shape it resembles;
- the background timer can neither read a credential nor open an SSH route, and
  never touches a broker whose tab is not visible;
- panel and detail buffers are `nofile` with swap files and undo files
  disabled, so ticket bodies and Cloudflare responses do not reach swap, undo,
  or log files;
- the plugin persists nothing.

Never weaken the broker, expose its admin listener, or move the capability
somewhere more convenient to restore compatibility with an older client.

The SSH account remains the authority boundary. Managed mode closes its route
with the review session; external mode leaves that responsibility to the
operator.

## Platform support

| Platform | Status    | CI                                |
| -------- | --------- | --------------------------------- |
| Linux    | Supported | Neovim 0.10.4, 0.11.7, and 0.12.4 |
| macOS    | Supported | Neovim 0.12.4 smoke test          |
| Windows  | Untested  | Contributions welcome             |

## Branch and release model

- `bet` is the production/default branch.
- `bluff` is the persistent integration branch.
- Focused branches merge into `bluff`; releases promote `bluff` into `bet`.
- Signed `vX.Y.Z` tags identify releases.

Each push to production `bet` can request a focused `mcp-buff` lockfile refresh
in `777lotto/nvim-config`. Configure the plugin repository secret
`NVIM_CONFIG_DISPATCH_TOKEN` with a fine-grained token scoped only to
`777lotto/nvim-config` and its Contents permission set to write. If the secret
is absent, the notification workflow exits successfully with a setup notice;
it never changes the plugin loopback, SSH, or network boundary.

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and pull-request guidance.

## Development

The suite mirrors `git-panel.nvim`:

```sh
nvim --headless --clean -l scripts/check-lua.lua .
nvim --headless -u tests/minimal_init.lua -l tests/unit.lua
nvim --headless -u tests/minimal_init.lua -l tests/smoke.lua
nvim --headless -u tests/minimal_init.lua -c "helptags doc" -c quit
git diff --check
git diff --exit-code -- doc/tags
```

The smoke test starts **two** dependency-free Node stubs on ephemeral loopback
ports, with two different capabilities, because two brokers is the thing under
test — a single stub could not catch a client that reused one socket's bearer
on the other.

`scripts/stub-admin-server.js` implements the Cloudflare admin contract: the
four gates in order and precedence, strict decision and permission schemas,
digest binding, synchronous terminal approval, lazy expiry, retention pruning,
HTML off-route bodies, and the 32kb-to-`500` behaviour.

`scripts/stub-git-admin-server.js` is its sibling and deliberately not a copy.
Its value is entirely in the places the two diverge — the `zemrip.git-ticket.v1`
domain, an approve that returns a non-terminal `approved`, `413` for an
oversized body, and a JSON `404` off-route — plus this broker's own ticket shape
and state machine, and a fixture whose request carries a term the workflow-push
shape does not declare, so the unrecognised-scope path is exercised over the
wire.

Both are driven through real curl, including a `capability_cmd` that is a
genuine external command. Nothing in the suite reaches a broker host or
provider.

The canonical JSON test vectors are copied verbatim from the broker's own
suite. If the two implementations ever disagree, the unit tests fail before
anything can be submitted. The unit suite also adds a scope to the GitHub
registry the way a future release would, and asserts nothing outside that
module has to change for it to be listed, described, and confirmed.

## Project layout

```text
mcp-buff/
├── .github/                    # CI, issue forms, and contribution templates
├── lua/mcp_buff/init.lua            # the tabbed panel, actions, timer, Lua API
├── lua/mcp_buff/broker.lua          # one broker connection: config, capability,
│                                    #   tunnel, client
├── lua/mcp_buff/sources/init.lua    # the source registry and the shape matcher
├── lua/mcp_buff/sources/cloudflare.lua  # Cloudflare's states, scopes, renderers
├── lua/mcp_buff/sources/github.lua      # the git broker's states, scopes,
│                                        #   renderers
├── lua/mcp_buff/client.lua          # loopback curl admin client
├── lua/mcp_buff/canonical.lua       # canonical JSON and both ticket digests
├── lua/mcp_buff/capability.lua      # in-memory admin capability acquisition
├── lua/mcp_buff/permissions.lua     # runtime-permission state and apply
├── lua/mcp_buff/tunnel.lua          # optional owned SSH-forward lifecycle
├── lua/mcp_buff/render.lua          # tab bar, lists, detail, confirmation
├── plugin/mcp-buff.lua              # lightweight command registration
├── doc/mcp-buff.txt                 # :help mcp-buff
├── scripts/check-lua.lua            # dependency-free compilation check
├── scripts/stub-admin-server.js     # the Cloudflare admin contract
├── scripts/stub-git-admin-server.js # the GitHub admin contract
└── tests/                           # focused unit tests and real HTTP smoke test
```

Adding a third broker is one file in `sources/`, one configuration key, and
nothing else. Adding a GitHub scope is one entry inside
`sources/github.lua`.

Run `:help mcp-buff` for the in-editor reference.

## License

mcp-buff is available under the [MIT License](LICENSE).
