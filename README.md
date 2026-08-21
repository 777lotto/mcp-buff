# mcp-buff

[![CI](https://github.com/777lotto/mcp-buff/actions/workflows/ci.yml/badge.svg?branch=bluff)](https://github.com/777lotto/mcp-buff/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io/)
[![Release](https://img.shields.io/github/v/release/777lotto/mcp-buff)](https://github.com/777lotto/mcp-buff/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A dependency-free Neovim review panel for `mcp-broker` write tickets. It lists
pending Cloudflare mutations, shows the complete stored request chain, and lets
the operator approve or deny through a loopback-only admin API reached over
SSH.

## Highlights

- Pending-first ticket list grouped by every broker status.
- Human-readable age, full ticket IDs, and reason excerpts in the panel.
- Markdown detail view with the full reason, pretty JSON bodies, results, and
  step-specific failures.
- Confirm-gated approval showing exactly what the broker will execute.
- Denial with an optional operator note.
- Cached `pending_count()` for statusline integrations.
- Manual refresh plus an optional timer that is off by default.
- No Neovim plugin dependencies and no Cloudflare credential handling.

## Requirements

- Neovim 0.10 or newer
- `curl` available on `PATH`
- an SSH tunnel to an installed `mcp-broker` admin listener

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
  },
}
```

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
ssh -N -L 8792:127.0.0.1:8792 zed@10.0.0.7
```

Keep that SSH process running. Stopping it revokes Toughbook reachability.
Never add `-g` or bind the local side to `0.0.0.0`.

As a preflight, this must return a ticket wrapper from the tunnel:

```sh
curl -fsS http://127.0.0.1:8792/tickets
```

## Configuration

```lua
require("mcp_buff").setup({
  endpoint = "http://127.0.0.1:8792",
  curl_command = "curl",
  timeout = 300000,      -- milliseconds; approval waits for broker execution
  refresh_interval = 0,  -- seconds; 0 keeps automatic refresh off
})
```

`setup()` rejects remote, bridge, HTTPS, path-bearing, and credential-bearing
endpoints. Curl ignores user configuration, does not follow redirects, and
sends denial JSON over standard input rather than process arguments.

Set `refresh_interval` to a positive whole number to refresh in the background.
Manual `r` remains available regardless. The default is intentionally off so
merely installing the plugin creates no recurring network activity.

## Command and controls

- `:McpBuff` opens the ticket panel as a left split.

Mappings are local to the panel buffer:

| Key | Action |
| --- | --- |
| `<CR>` | Fetch and open the complete current ticket |
| `a` | Re-fetch, review, confirm, and approve a pending ticket |
| `d` | Re-fetch and deny a pending ticket with an optional note |
| `r` | Refresh the ticket list |
| `q` | Close the panel |

`<NL>` and keypad Enter work like `<CR>`, matching terminal-safe GitPanel
behavior. Detail windows close with `q` or `<Esc>`.

## Review behavior

The list always renders groups in this order:

1. pending
2. approved
3. executing
4. failed
5. denied
6. expired
7. executed

Approval does not trust the cached list row. Pressing `a` first fetches the
full ticket again and refuses anything no longer pending. The confirmation
contains the complete reason and every stored method, literal path, and
pretty-printed body. Only after the explicit **Approve** choice does the plugin
call `POST /tickets/:id/approve`.

The broker endpoint executes synchronously. McpBuff keeps Neovim responsive
while curl waits, then opens the returned final ticket so partial results, the
failed step, and the broker error are immediately visible. It cannot edit a
ticket or supply replacement requests at approval time.

Denial follows the same fresh-read rule, accepts an optional note, and requires
a final confirmation before `POST /tickets/:id/deny`.

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
- request bodies travel on curl standard input;
- curl user configuration and redirects are disabled;
- approve and deny operate only on a broker-shaped ticket ID;
- approval sends no request body, so no plugin or user input can replace the
  already-stored requests;
- the plugin does not persist ticket data, reasons, responses, or notes.

The SSH account remains the authority boundary. Close the tunnel when review is
finished.

## Platform support

| Platform | Status | CI |
| --- | --- | --- |
| Linux | Supported | Neovim 0.10.4, 0.11.7, and 0.12.4 |
| macOS | Supported | Neovim 0.12.4 smoke test |
| Windows | Untested | Contributions welcome |

## Branch and release model

- `bet` is the production branch once the first tested release is promoted.
- `bluff` is the persistent integration/default branch.
- Focused branches merge into `bluff`; releases promote `bluff` into `bet`.
- Signed `vX.Y.Z` tags identify releases.

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
`scripts/stub-admin-server.js` on an ephemeral loopback port. It exercises the
real curl transport, panel/detail rendering, approval, denial, refresh, and
`pending_count()` without touching a box or Cloudflare.

## Project layout

```text
mcp-buff/
├── .github/                    # CI, issue forms, and contribution templates
├── lua/mcp_buff/init.lua       # panel, actions, timer, and public Lua API
├── lua/mcp_buff/client.lua     # loopback curl admin client
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
