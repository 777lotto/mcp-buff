# Contributing

Issues and pull requests should describe the ticket-review problem first, then
the proposed behavior.

## Branch model

- `bet` is the production/default branch.
- `bluff` is the persistent integration branch.
- Short-lived work branches start from and return to `bluff`.
- A `bluff` → `bet` pull request promotes a tested release candidate.

Do not target `bet` directly for ordinary changes.

## Local checks

Run these from the repository root with Neovim 0.10 or newer, Node, and curl:

```sh
nvim --headless --clean -l scripts/check-lua.lua .
nvim --headless -u tests/minimal_init.lua -l tests/unit.lua
nvim --headless -u tests/minimal_init.lua -l tests/smoke.lua
nvim --headless -u tests/minimal_init.lua -c "helptags doc" -c quit
git diff --check
git diff --exit-code -- doc/tags
```

Keep the plugin dependency-free unless a proposal demonstrates that a new
dependency materially improves the core approval workflow. Add a focused unit
assertion or stub-admin smoke reproduction for behavior changes.

Tests must use obvious fixture IDs and loopback stub data. Never put a
Cloudflare token, token-shaped string, real account/zone ID, SSH credential, or
private infrastructure response in the repository.

Use [Discussions](https://github.com/777lotto/mcp-buff/discussions) for
questions, setup showcases, and exploratory ideas. Open an Issue when work is
reproducible and actionable.

Human commits should be signed with a GitHub-verified GPG, SSH, or S/MIME
signature. Approved automation commits may be explicitly unsigned. Open the
pull request into `bluff`, complete the checklist, and wait for CI.
