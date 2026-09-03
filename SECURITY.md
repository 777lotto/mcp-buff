# Security policy

## Supported versions

Security fixes are applied to the current `bluff` branch and latest release.

## Reporting a vulnerability

Do not open a public issue for a suspected approval bypass, unsafe command
construction, endpoint escape, ticket-data exposure, or SSH-boundary flaw. Use
the repository's **Security** tab and select **Report a vulnerability**.

Include the affected commit or release, a minimal reproduction using synthetic
tickets, expected impact, and any suggested mitigation. You should receive an
initial response within seven days.

## Broker authority boundary

McpBuff accepts only `http://127.0.0.1:PORT` endpoints and is intended to reach
the broker admin API through an operator-opened SSH local forward. It does not
accept or handle Cloudflare credentials. Do not weaken the endpoint check or
add a token configuration path.

Approval always re-fetches the complete ticket, confirms its stored methods,
literal paths, and bodies, then posts an empty approval request. The client has
no update endpoint and cannot replace broker-stored execution input.

Curl ignores user-level configuration, does not follow redirects, uses argv
arrays rather than a shell, and sends JSON bodies over standard input. Ticket
data remains in Neovim memory only; reports involving persistence, process
arguments, rendering, confirmation truncation, redirects, or a non-loopback
request should be submitted privately under this policy.
