# Contributing

Issues and pull requests should describe the ticket-review problem first, then
the proposed behavior.

## Branch model

- `bluff` is the default and only long-lived branch.
- Short-lived work branches start from and return to `bluff`.
- CI publishes unsigned version tags and Releases from tested `bluff` commits.
  See [automatic releases](docs/releases.md); human-created tags may still be signed.

## Local checks

Run `bash scripts/test-release-tested.sh` to check release selection and retry
behavior against local fixtures.

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
signature. Approved automation commits and brokered `zemrip-ai` commits may be
explicitly unsigned. On the agent plane, pushes are limited to `agent/**`;
workflow changes also require an operator-approved one-use ticket. The broker
cannot push `bluff` or tags, publish Releases, or administer repository
secrets. Open the pull request into `bluff`, complete the checklist, and wait
for CI.
