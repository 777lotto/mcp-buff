// Dependency-free stand-in for the github-broker admin API on 127.0.0.1:8793.
//
// Sibling of scripts/stub-admin-server.js, and deliberately not a copy of it.
// The two brokers share a wire contract, so the value of this file is entirely
// in the four places they diverge — each marked DIVERGENCE below — plus the
// ticket shape and state machine that are this broker's own:
//
//   * the digest domain is zemrip.git-ticket.v1, so a digest the operator typed
//     for a Cloudflare ticket is not a valid digest here;
//   * approve does not execute anything. It returns `approved`, which is not
//     terminal: the push that spends the grant happens later, on another
//     connection, and may never come;
//   * an oversized body answers 413, not the sibling's fall-through 500;
//   * an off-route request answers JSON, not Express's HTML finalhandler.
//
// It binds loopback only and never speaks to GitHub.

const http = require("node:http");
const { createHash, timingSafeEqual } = require("node:crypto");

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("usage: node scripts/stub-git-admin-server.js PORT [CAPABILITY]");
}
const capability = process.argv[3] ?? "b".repeat(64);
if (!/^[a-f0-9]{64}$/.test(capability)) {
  throw new Error("CAPABILITY must be 64 lowercase hex characters");
}

const MAX_BODY_BYTES = 32 * 1024;
const MAX_NOTE_LENGTH = 4000;
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

// DIVERGENCE 1: a different domain separator for the same five immutable
// fields. Different power, different digest domain.
const DIGEST_PREFIX = "zemrip.git-ticket.v1";

// DIVERGENCE 2: `approved` has outgoing transitions, so it is not terminal.
const TRANSITIONS = {
  pending: ["approved", "denied", "expired"],
  approved: ["consumed", "expired"],
  denied: [],
  expired: [],
  consumed: [],
};
const isTerminal = (status) => TRANSITIONS[status].length === 0;

const TICKET_STATUSES = ["pending", "approved", "denied", "expired", "consumed"];

// ---------------------------------------------------------------------------
// Canonical JSON and the immutable ticket digest, ported from the broker.
// ---------------------------------------------------------------------------

function canonicalJson(value) {
  if (value === null || typeof value !== "object") {
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw new TypeError("value is not JSON");
    return encoded;
  }
  if (Array.isArray(value)) {
    return `[${value.map((child) => canonicalJson(child)).join(",")}]`;
  }
  return `{${Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
    .join(",")}}`;
}

function ticketSha256(ticket) {
  const payload = {
    id: ticket.id,
    created: ticket.created,
    expires: ticket.expires,
    reason: ticket.reason,
    requests: ticket.requests,
  };
  return createHash("sha256")
    .update(`${DIGEST_PREFIX}\n${canonicalJson(payload)}`, "utf8")
    .digest("hex");
}

// ---------------------------------------------------------------------------
// Fixtures. Timestamps are relative to process start so the suite does not rot.
// ---------------------------------------------------------------------------

const startedAt = Date.now();
const at = (offsetMs) => new Date(startedAt + offsetMs).toISOString();
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const ids = {
  approve: "t_20260903T090000.000Z_0000000000b1",
  deny: "t_20260903T090100.000Z_0000000000b2",
  granted: "t_20260903T083000.000Z_0000000000b3",
  overdue: "t_20260903T070000.000Z_0000000000b4",
  spent: "t_20260903T080000.000Z_0000000000b5",
  prunable: "t_20250903T080000.000Z_0000000000b6",
  // A ticket whose request carries a key this release's workflow-push shape
  // does not declare. The client must render it as an unrecognised scope rather
  // than describing it with the shape it nearly matches.
  future: "t_20260903T085500.000Z_0000000000b7",
  // Pending, and decided from inside the panel's preview window rather than
  // from the list, so the suite can prove which ticket a keystroke taken there
  // acts on.
  preview: "t_20260903T085000.000Z_0000000000b8",
};

function workflowPush(repo, refs) {
  return { repo, refs: [...refs].sort() };
}

function ticket(id, createdOffset, expiresOffset, reason, requests, overrides = {}) {
  const base = {
    ticket_version: 1,
    id,
    created: at(createdOffset),
    expires: at(expiresOffset),
    reason,
    requests,
    status: "pending",
  };
  return { ...base, ticket_sha256: ticketSha256(base), ...overrides };
}

const seed = [
  ticket(
    ids.approve,
    -6 * MINUTE,
    2 * HOUR,
    "add a nightly Actions workflow for the postgres18 suite",
    [workflowPush("777lotto/zemrip", ["refs/heads/agent/ci-nightly"])],
  ),
  ticket(
    ids.deny,
    -5 * MINUTE,
    2 * HOUR,
    "rewrite release.yml across three agent branches",
    [
      workflowPush("777lotto/zemrip", [
        "refs/heads/agent/release-a",
        "refs/heads/agent/release-b",
        "refs/heads/agent/release-c",
      ]),
    ],
  ),
  // Approved and unspent: a live grant. The panel must show it as its own
  // state, not file it with the finished work.
  ticket(
    ids.granted,
    -30 * MINUTE,
    2 * HOUR,
    "approved earlier; the push has not happened yet",
    [workflowPush("777lotto/mcp-buff", ["refs/heads/agent/ci-matrix"])],
    { status: "approved" },
  ),
  // Past its expiry: a read must lazily expire it rather than serve it pending.
  ticket(
    ids.overdue,
    -4 * HOUR,
    -2 * HOUR,
    "pending ticket whose TTL already elapsed",
    [workflowPush("777lotto/zemrip", ["refs/heads/agent/stale"])],
  ),
  ticket(
    ids.spent,
    -60 * MINUTE,
    HOUR,
    "spent grant from an earlier review",
    [workflowPush("777lotto/git-panel", ["refs/heads/agent/actions-cache"])],
    { status: "consumed", consumed: at(-58 * MINUTE) },
  ),
  // Terminal and older than the retention window: a listing call must unlink it.
  ticket(
    ids.prunable,
    -400 * DAY,
    -400 * DAY + HOUR,
    "terminal ticket past the retention window",
    [workflowPush("777lotto/zemrip", ["refs/heads/agent/ancient"])],
    { status: "denied", denial_note: "denied long ago" },
  ),
  ticket(
    ids.future,
    -8 * MINUTE,
    2 * HOUR,
    "a scope newer than this panel",
    [
      {
        repo: "777lotto/zemrip",
        refs: ["refs/heads/agent/settings"],
        // The extra term. A tolerant client would render this ticket as an
        // ordinary workflow push and never show the operator this line.
        branch_protection: "disable",
      },
    ],
  ),
  ticket(
    ids.preview,
    -7 * MINUTE,
    2 * HOUR,
    "add a coverage upload step to the smoke workflow",
    [workflowPush("777lotto/mcp-buff", ["refs/heads/agent/coverage-upload"])],
  ),
];

const tickets = new Map();
for (const entry of seed) tickets.set(entry.id, entry);

let ticketListRequests = 0;
let decisionPosts = 0;
let permissionPosts = 0;

// ---------------------------------------------------------------------------
// Runtime permissions: this broker's compiled registry.
// ---------------------------------------------------------------------------

const permissionDefinitions = [
  { id: "github.mcp", title: "GitHub MCP", description: "Use the upstream GitHub MCP server with its compiled read/issue scope." },
  { id: "github.git.read", title: "Git fetch and clone", description: "Read repositories through Git smart HTTP." },
  { id: "github.git.write", title: "Agent branch push", description: "Push only refs/heads/agent/** through the ordinary Git route." },
  { id: "github.workflow.write", title: "Reviewed workflow push", description: "Create, approve, and spend tickets for workflow-changing agent pushes." },
  { id: "github.api.read", title: "GitHub API reads", description: "Use allowlisted repository, installation, and rate-limit reads." },
  { id: "github.issues.write", title: "Issues and milestones", description: "Create and edit allowlisted issues, comments, labels, and milestones." },
  { id: "github.pull_requests.write", title: "Pull requests", description: "Create and edit pull requests, comments, and reviewer requests." },
  { id: "github.merge", title: "Gated pull-request merge", description: "Merge only after the broker's reviewed approval/automerge gate passes." },
];
let enabledPermissions = new Set(permissionDefinitions.map(({ id }) => id));

function permissionsSnapshot() {
  const enabled = [...enabledPermissions].sort();
  return {
    provider: "github",
    permissions_sha256: createHash("sha256")
      .update(
        `zemrip.broker-permissions.v1\ngithub\n${JSON.stringify(enabled)}`,
        "utf8",
      )
      .digest("hex"),
    permissions: permissionDefinitions.map((permission) => ({
      ...permission,
      enabled: enabledPermissions.has(permission.id),
      ceiling: true,
    })),
  };
}

// ---------------------------------------------------------------------------
// Store behaviour
// ---------------------------------------------------------------------------

/** Expiry is lazy: it fires on every read and every decision, never on a timer. */
function settle(entry) {
  if (isTerminal(entry.status)) return entry;
  if (Date.now() < Date.parse(entry.expires)) return entry;
  const expired = { ...entry, status: "expired" };
  tickets.set(expired.id, expired);
  return expired;
}

/** GET /tickets is the sweep: it expires the overdue and prunes the aged. */
function listAndMaintain(status) {
  const cutoff = Date.now() - RETENTION_MS;
  const visible = [];
  for (const stored of [...tickets.values()]) {
    const entry = settle(stored);
    if (isTerminal(entry.status) && Date.parse(entry.created) < cutoff) {
      tickets.delete(entry.id);
      continue;
    }
    if (status === null || entry.status === status) visible.push(entry);
  }
  visible.sort((left, right) => right.created.localeCompare(left.created));
  // No result_count: this broker's approval executes nothing, so there are no
  // results to count.
  return visible.map((entry) => ({
    id: entry.id,
    created: entry.created,
    expires: entry.expires,
    status: entry.status,
    ticket_sha256: entry.ticket_sha256,
    reason: entry.reason,
    request_count: entry.requests.length,
  }));
}

// ---------------------------------------------------------------------------
// Responses and gates
// ---------------------------------------------------------------------------

function json(response, status, body, headers = {}) {
  const encoded = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(encoded),
    ...headers,
  });
  response.end(encoded);
}

function digestOf(value) {
  return createHash("sha256").update(value, "utf8").digest();
}

function validBearer(authorization) {
  return timingSafeEqual(
    digestOf(`Bearer ${capability}`),
    digestOf(authorization ?? ""),
  );
}

/**
 * Origin, then Host, then bearer, then (POST only) content type.
 *
 * The order is client-visible and identical to the sibling's: a status names
 * the first gate that failed, never the worst thing wrong with the request.
 */
function runGates(request, response) {
  if (Object.prototype.hasOwnProperty.call(request.headers, "origin")) {
    json(response, 403, { error: "origin not allowed" });
    return false;
  }
  const localPort = request.socket.localPort;
  if (
    request.socket.localAddress !== "127.0.0.1" ||
    request.headers.host !== `127.0.0.1:${localPort}`
  ) {
    json(response, 400, { error: "invalid host" });
    return false;
  }
  if (!validBearer(request.headers.authorization)) {
    json(response, 401, { error: "unauthorized" }, { "www-authenticate": "Bearer" });
    return false;
  }
  if (request.method === "POST") {
    const value = request.headers["content-type"];
    const media =
      typeof value === "string" ? value.split(";", 1)[0].trim().toLowerCase() : "";
    if (media !== "application/json") {
      json(response, 415, { error: "application/json required" });
      return false;
    }
  }
  return true;
}

class PayloadTooLargeError extends Error {}
class InvalidJsonError extends Error {}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new PayloadTooLargeError();
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  const text = Buffer.concat(chunks).toString("utf8");
  if (text.trim() === "") return {};
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new InvalidJsonError();
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new InvalidJsonError();
  }
  return parsed;
}

const DIGEST_PATTERN = /^[a-f0-9]{64}$/;

/** Strict: ticket_sha256 required, note on deny only, nothing else accepted. */
function parseDecision(action, body) {
  const issues = [];
  if (!DIGEST_PATTERN.test(body.ticket_sha256 ?? "")) {
    issues.push("ticket_sha256 must be 64 lowercase hex characters");
  }
  let note;
  if (body.note !== undefined) {
    if (action !== "deny") {
      issues.push("note is not accepted on approve");
    } else if (typeof body.note !== "string") {
      issues.push("note must be a string");
    } else {
      const trimmed = body.note.trim();
      if (trimmed.length < 1 || trimmed.length > MAX_NOTE_LENGTH) {
        issues.push(`note must be 1..${MAX_NOTE_LENGTH} characters`);
      } else {
        note = trimmed;
      }
    }
  }
  for (const key of Object.keys(body)) {
    if (key !== "ticket_sha256" && key !== "note") issues.push(`unexpected key ${key}`);
  }
  if (issues.length > 0) return { issues };
  return { digest: body.ticket_sha256, note };
}

function decide(action, entry, parsed, response) {
  // The digest is checked before the state machine. It guards cross-ticket and
  // cross-broker replay and tampering, not a concurrent decision: the five
  // immutable fields never change, so a ticket decided elsewhere still matches.
  if (parsed.digest !== entry.ticket_sha256) {
    return json(response, 409, {
      error: `ticket ${entry.id} digest does not match the reviewed immutable payload`,
    });
  }
  const to = action === "approve" ? "approved" : "denied";
  if (!TRANSITIONS[entry.status].includes(to)) {
    return json(response, 409, {
      error: `ticket ${entry.id} cannot transition from ${entry.status} to ${to}`,
    });
  }
  const decided = { ...entry, status: to };
  if (to === "denied" && parsed.note !== undefined) decided.denial_note = parsed.note;
  tickets.set(decided.id, decided);
  // DIVERGENCE 2, on the wire: a successful approve returns `approved`. Nothing
  // executed, and the ticket still has a transition left.
  return json(response, 200, decided);
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

const TICKET_ID = /^t_\d{8}T\d{6}\.\d{3}Z_[a-f0-9]{12}$/;

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  const pathname = url.pathname;

  // Test scaffolding, outside the admin contract and outside the gates.
  if (request.method === "GET" && pathname === "/health") {
    return json(response, 200, { ok: true });
  }
  if (request.method === "GET" && pathname === "/__stats") {
    return json(response, 200, {
      ticket_list_requests: ticketListRequests,
      decision_posts: decisionPosts,
      permission_posts: permissionPosts,
      ids,
      ticket_count: tickets.size,
    });
  }

  response.setHeader("cache-control", "no-store");
  if (!runGates(request, response)) return;

  if (request.method === "GET" && pathname === "/permissions") {
    return json(response, 200, permissionsSnapshot());
  }

  if (request.method === "POST" && pathname === "/permissions") {
    permissionPosts += 1;
    let body;
    try {
      body = await readJsonBody(request);
    } catch (error) {
      if (error instanceof PayloadTooLargeError) {
        return json(response, 413, { error: "request body too large" });
      }
      return json(response, 400, { error: "invalid JSON body" });
    }
    if (Object.keys(body).sort().join(",") !== "enabled,permissions_sha256") {
      return json(response, 400, {
        error: "body must contain exactly enabled and permissions_sha256",
      });
    }
    if (!DIGEST_PATTERN.test(body.permissions_sha256 ?? "")) {
      return json(response, 400, {
        error: "permissions_sha256 must be 64 lowercase hex characters",
      });
    }
    if (!Array.isArray(body.enabled)) {
      return json(response, 400, { error: "enabled must be an array" });
    }
    const known = new Set(permissionDefinitions.map(({ id }) => id));
    const next = new Set();
    for (const id of body.enabled) {
      if (typeof id !== "string" || !known.has(id)) {
        return json(response, 400, { error: `unknown permission ${String(id)}` });
      }
      if (next.has(id)) return json(response, 400, { error: `duplicate permission ${id}` });
      next.add(id);
    }
    if (body.permissions_sha256 !== permissionsSnapshot().permissions_sha256) {
      return json(response, 409, {
        error: "permissions changed since they were read; refresh before applying",
      });
    }
    enabledPermissions = next;
    return json(response, 200, permissionsSnapshot());
  }

  if (request.method === "GET" && pathname === "/tickets") {
    ticketListRequests += 1;
    const status = url.searchParams.get("status");
    if (status !== null && !TICKET_STATUSES.includes(status)) {
      return json(response, 400, {
        error: "invalid request",
        issues: [`unknown status ${status}`],
      });
    }
    return json(response, 200, { tickets: listAndMaintain(status) });
  }

  const detail = pathname.match(/^\/tickets\/([^/]+)$/);
  if (request.method === "GET" && detail) {
    const id = decodeURIComponent(detail[1]);
    if (!TICKET_ID.test(id) || !tickets.has(id)) {
      return json(response, 404, { error: "no such ticket" });
    }
    // GET /tickets/:id expires but never prunes.
    return json(response, 200, settle(tickets.get(id)));
  }

  const action = pathname.match(/^\/tickets\/([^/]+)\/(approve|deny)$/);
  if (request.method === "POST" && action) {
    decisionPosts += 1;
    const id = decodeURIComponent(action[1]);
    let body;
    try {
      body = await readJsonBody(request);
    } catch (error) {
      // DIVERGENCE 3: 413, not the sibling's fall-through 500. An overlong
      // denial note is a thing the client did, not a broker fault.
      if (error instanceof PayloadTooLargeError) {
        return json(response, 413, { error: "request body too large" });
      }
      return json(response, 400, { error: "invalid JSON body" });
    }
    const parsed = parseDecision(action[2], body);
    if (parsed.issues) {
      return json(response, 400, { error: "invalid request", issues: parsed.issues });
    }
    if (!TICKET_ID.test(id) || !tickets.has(id)) {
      return json(response, 404, { error: "no such ticket" });
    }
    return decide(action[2], settle(tickets.get(id)), parsed, response);
  }

  // DIVERGENCE 4: this broker's admin handler owns its own 404 and answers
  // JSON. The sibling has no catch-all and falls through to Express's HTML
  // finalhandler, so a client must not assume either shape.
  return json(response, 404, { error: "no such route" });
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`ready ${port}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
