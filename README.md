# mcp-buff

[![CI](https://github.com/777lotto/mcp-buff/actions/workflows/ci.yml/badge.svg?branch=bet)](https://github.com/777lotto/mcp-buff/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io/)
[![Release](https://img.shields.io/github/v/release/777lotto/mcp-buff)](https://github.com/777lotto/mcp-buff/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A dependency-free Neovim review panel for `mcp-broker` write tickets. It lists
pending Cloudflare mutations, shows the complete stored request chain, and lets
the operator approve or deny through a loopback-only admin API reached over
SSH.

## Highlights

- Pending-first ticket list grouped by every broker status, with
  `indeterminate` as its own state rather than a kind of failure.
- Markdown detail view with the full reason, the expiry, the complete
  `ticket_sha256`, pretty JSON bodies, structured preconditions, preflight
  observations, and results.
- The admin capability is fetched from a command you supply and kept in memory
  only — never in argv, the environment, on disk, or in a log.
- `ticket_sha256` is recomputed locally and disagreement is a hard refusal.
- Typed digest confirmation. No single-keypress approval, no yes/no prompt.
- A decision is never resubmitted: an unaccounted-for POST is resolved by
  polling the same ticket.
- Cached `pending_count()` for statusline integrations.
- Manual refresh plus an optional timer that is off by default and can never
  raise a credential prompt.
- No Neovim plugin dependencies and no Cloudflare credential handling.

## Requirements

- Neovim 0.10 or newer
- `curl` available on `PATH`
- an SSH tunnel to an installed `mcp-broker` admin listener
- a command that prints the broker's admin capability, such as a `pass` entry

The plugin deliberately accepts only endpoints in the form
`http://127.0.0.1:PORT`. It never connects to the Incus bridge, the container,
or Cloudflare directly.

## Installation

With lazy.nvim, matching the `nvim-config` GitPanel pattern:

```lua
{
  "777lotto/mcp-buff",
  main = "mcp_buff",
  cmd = { "McpBuff" },
  keys = {
    { "<leader>mb", "<cmd>McpBuff<cr>", desc = "Cloudflare write tickets" },
  },
  opts = {
    endpoint = "http://127.0.0.1:8792",
    capability_cmd = { "pass", "show", "your/broker/admin-capability" },
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

## Open the approval tunnel

The broker admin API binds only to box loopback. Open this tunnel on the
Toughbook before starting the panel:

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

Keep that SSH process running. Stopping it revokes reachability. Never add `-g`
or bind the local side to `0.0.0.0`.

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
re-run the command for every request, and is dropped when the panel closes,
when Neovim exits, and whenever `setup()` runs again. A `401` triggers exactly
one forced re-read, in case the capability was rotated mid-session; after that
the failure is surfaced rather than retried.

A failed capability read **aborts the request**. mcp-buff never falls back to
an unauthenticated send, because that failure reaches you as an opaque `401`
rather than as "your card is not available".

The background refresh timer never runs `capability_cmd`. If the cached value
has expired, the tick is skipped instead — a credential prompt storm is
structurally impossible, not merely unlikely. Press `r` to acquire one again.

## Configuration

```lua
require("mcp_buff").setup({
  endpoint = "http://127.0.0.1:8792",
  capability_cmd = nil,     -- required; argv list, run with no shell
  capability_ttl = 300,     -- seconds the capability is held in memory
  curl_command = "curl",
  timeout = 30000,          -- milliseconds; reads only
  decision_timeout = 1865,  -- seconds; the approve/deny POST
  poll_deadline = 1865,     -- seconds; outcome polling after a failed POST
  refresh_interval = 0,     -- seconds; 0 keeps automatic refresh off
  host_header = nil,        -- e.g. "127.0.0.1:8792" for an asymmetric forward
})
```

`setup()` rejects remote, bridge, HTTPS, path-bearing, and credential-bearing
endpoints. Curl ignores user configuration and does not follow redirects.

**The two timeouts are different budgets and are deliberately not shared.**
`timeout` covers reads, which perform no execution — a read that hangs for half
an hour is a broken tunnel, not a long approval. `decision_timeout` covers the
approve and deny POST, inside which the broker performs every preflight GET and
every mutation: up to ten requests, each incurring two preflight GETs and a
mutation, each individually timed at the broker's own 60s default. The worst
case is far longer than a conventional HTTP timeout, which is why the default is
`1865`. Both `decision_timeout` and `poll_deadline` are clamped to `65..86400`.

Neither timeout bounds your review time. That is bounded only by the ticket's
expiry, which the detail view always shows.

Set `refresh_interval` to a positive whole number to refresh in the background.
Manual `r` remains available regardless. The default is intentionally off so
merely installing the plugin creates no recurring network activity.

## Command and controls

- `:McpBuff` opens the ticket panel as a left split.

Mappings are local to the panel buffer:

| Key | Action |
| --- | --- |
| `<CR>` | Fetch and open the complete current ticket |
| `a` | Re-fetch, review, type the digest confirmation, and approve |
| `d` | Re-fetch, review, type the digest confirmation, and deny with an optional note |
| `r` | Refresh the ticket list |
| `q` | Close the panel |

`<NL>` and keypad Enter work like `<CR>`, matching terminal-safe GitPanel
behavior. Detail windows close with `q` or `<Esc>`.

## Review behavior

The list always renders groups in this order:

1. pending
2. approved
3. executing
4. indeterminate
5. failed
6. denied
7. expired
8. executed

A decision does not trust the cached list row. Pressing `a` or `d` re-fetches
the full ticket, refuses anything that is not `pending`, and renders the
reason, the expiry, the complete digest, every stored method, literal path and
pretty-printed body, each request's structured precondition, and every
preflight observation.

### Digest recomputation

The digest covers exactly `id`, `created`, `expires`, `reason` and `requests`:

```text
sha256("zemrip.mcp-ticket.v1" + "\n" + canonicalJson(payload))
```

mcp-buff recomputes it locally and refuses to submit when the result disagrees
with the served value. It also refuses when the payload contains anything it
cannot canonicalise to the same bytes the broker would produce — in practice a
non-integer number or a non-ASCII object key. Refusing is deliberate: a guessed
digest would let you approve a payload you had not actually verified.

The digest catches a cross-ticket replay, a client-side digest bug, and direct
tampering with the stored ticket. It does **not** detect a concurrent decision:
the five immutable fields never change, so a ticket approved, denied, or
expired between your read and your submission keeps an identical digest. That
race is caught by the ticket state machine instead.

### Typed confirmation

After the render, mcp-buff requires you to type the final eight characters of
the digest:

```text
ticket_sha256: 9f2c…a41b7e3d
Type the final digest bytes a41b7e3d to approve:
```

There is no single-keypress approval and no yes/no prompt. Anything other than
the exact suffix cancels and nothing is sent.

### Outcomes

A decision is **never resubmitted**. Resubmitting cannot execute a ticket twice
— the state machine has no edge back to `approved` — but the resulting `409`
destroys the account of what happened: it has the same shape as an expiry and a
denial made elsewhere, and tells you only where the ticket stands now, not
whether your first submission's mutations reached Cloudflare.

So when a decision POST fails, times out, or returns a body mcp-buff cannot
read, it polls that same ticket every two seconds until it reaches a terminal
state, up to `poll_deadline`. On the deadline, or if the ticket cannot be
fetched at all, it reports the outcome as unknown and stops. When the broker
refuses outright — a gate failure, a `404`, or either `409` — nothing was
touched, so the refusal is reported directly and nothing is polled.

Approval executes synchronously inside the POST, so a `200` from approve is
always terminal. `indeterminate` means the outcome is genuinely unknown: a
mutation may or may not have reached Cloudflare. It is rendered as its own
state, never as a failure, and it is not a retry signal.

### Errors you will see

The four transport gates have distinct statuses and share one ordered
middleware chain: Origin (`403`), Host (`400`), bearer (`401`), then content
type (`415`) on POSTs only. A status names the *first* gate that failed, not the
worst thing wrong with the request, so a bad `Host` masks a missing capability
and answers `400` rather than `401`. Fix them in that order.

- `400 {"error":"invalid host"}` is a configuration fault — an asymmetric
  forward. It is never a retryable body error and must not prompt a resubmit.
- Both `409`s share a status and are separated only by message text: a digest
  mismatch, or a state transition that is no longer legal — which after a
  pending render means the ticket expired or was decided while you reviewed.
- A `500` on a decision may be nothing worse than a note over the broker's 32kb
  body cap, so it is treated as an unknown outcome and polled.
- An off-route request returns **HTML**, not JSON. Error bodies are decoded
  defensively and this is reported as a wrong route.
- A terminal ticket is unlinked once past the broker's retention window and
  then `404`s. Listing tickets is what expires the overdue and prunes the aged,
  so the list is not a pure read.

## Statusline API

`pending_count()` is intentionally nonblocking and returns the latest cached
count. It is `0` before the first successful refresh.

Example lualine component:

```lua
function()
  local count = require("mcp_buff").pending_count()
  return count > 0 and ("CF writes: " .. count) or ""
end
```

Enable the optional timer if the statusline should stay current while the panel
is closed.

## Security boundary

McpBuff speaks only the broker admin API. It has no dependency on zemRip, no
Cloudflare API client, and no place to configure a read or write token.

- the endpoint is syntactically restricted to IPv4 loopback;
- the capability is the only secret, and it travels on the private channel — a
  curl configuration file on standard input, never argv, the environment, disk,
  or a log;
- the decision body is not secret and travels through ordinary process
  arguments. Process arguments are visible to other processes running as your
  user, so do not type anything into a denial note you would not put in `ps`
  output;
- curl user configuration and redirects are disabled, and no shell is involved
  anywhere, including the capability fetch;
- approve and deny operate only on a broker-shaped ticket ID and send only what
  the strict schemas allow;
- approve and deny send only the digest of the ticket the broker already
  stored, so no plugin or user input can replace the stored requests;
- panel and detail buffers are `nofile` with swap files and undo files
  disabled, so ticket bodies and Cloudflare responses do not reach swap, undo,
  or log files;
- the plugin persists nothing.

Never weaken the broker, expose its admin listener, or move the capability
somewhere more convenient to restore compatibility with an older client.

The SSH account remains the authority boundary. Close the tunnel when review is
finished.

## Platform support

| Platform | Status | CI |
| --- | --- | --- |
| Linux | Supported | Neovim 0.10.4, 0.11.7, and 0.12.4 |
| macOS | Supported | Neovim 0.12.4 smoke test |
| Windows | Untested | Contributions welcome |

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

The smoke test starts the dependency-free Node stub in
`scripts/stub-admin-server.js` on an ephemeral loopback port. The stub
implements the hardened admin contract — the four gates in order and
precedence, strict decision schemas, digest binding, synchronous terminal
approval, lazy expiry, retention pruning, HTML off-route bodies, and the
32kb-to-`500` behaviour — so the suite exercises the real contract over real
curl, including a `capability_cmd` that is a genuine external command. Nothing
in the suite reaches a broker host or Cloudflare.

The canonical JSON test vectors are copied verbatim from the broker's own
suite. If the two implementations ever disagree, the unit tests fail before
anything can be submitted.

## Project layout

```text
mcp-buff/
├── .github/                    # CI, issue forms, and contribution templates
├── lua/mcp_buff/init.lua       # panel, actions, timer, and public Lua API
├── lua/mcp_buff/client.lua     # loopback curl admin client
├── lua/mcp_buff/canonical.lua  # canonical JSON and the ticket digest
├── lua/mcp_buff/capability.lua # in-memory admin capability acquisition
├── lua/mcp_buff/render.lua     # list, detail, confirmation, and JSON rendering
├── plugin/mcp-buff.lua         # lightweight command registration
├── doc/mcp-buff.txt            # :help mcp-buff
├── scripts/check-lua.lua       # dependency-free compilation check
├── scripts/stub-admin-server.js
└── tests/                      # focused unit tests and real HTTP smoke test
```

Run `:help mcp-buff` for the in-editor reference.

## License

mcp-buff is available under the [MIT License](LICENSE).
