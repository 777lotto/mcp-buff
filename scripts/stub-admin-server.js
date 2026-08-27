// Dependency-free stand-in for the hardened mcp-broker admin API.
//
// This exists so the test suite can prove the client against the real wire
// contract instead of against a summary of it: the four transport gates in
// their documented order and precedence, strict decision schemas, digest
// binding, synchronous terminal approval, lazy expiry, retention pruning, and
// the handful of behaviours a client author would otherwise guess wrong (HTML
// off-route bodies, an oversized body answering 500 rather than 413).
//
// It binds loopback only and never speaks to anything upstream.

const http = require("node:http");
const { createHash, timingSafeEqual } = require("node:crypto");

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("usage: node scripts/stub-admin-server.js PORT [CAPABILITY]");
}
const capability = process.argv[3] ?? "a".repeat(64);
if (!/^[a-f0-9]{64}$/.test(capability)) {
  throw new Error("CAPABILITY must be 64 lowercase hex characters");
}

const BODY_LIMIT_BYTES = 32 * 1024;
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const TERMINAL = new Set([
  "executed",
  "failed",
  "indeterminate",
  "denied",
  "expired",
]);

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
    .update(`zemrip.mcp-ticket.v1\n${canonicalJson(payload)}`, "utf8")
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
  approve: "t_20260820T180000.000Z_0000000000a1",
  deny: "t_20260820T180100.000Z_0000000000a2",
  executed: "t_20260820T170000.000Z_0000000000a3",
  overdue: "t_20260820T160000.000Z_0000000000a4",
  prunable: "t_20260820T150000.000Z_0000000000a5",
  indeterminate: "t_20260820T140000.000Z_0000000000a6",
};

function dnsRequest(path) {
  return {
    method: "PATCH",
    path,
    body: { comment: "stub no-op", metadata: { reviewed: true } },
    precondition: {
      method: "GET",
      path,
      expect: { status: 200, result_sha256: "1".repeat(64) },
    },
  };
}

function pending(id, createdOffset, expiresOffset, reason, path) {
  return {
    ticket_version: 1,
    id,
    created: at(createdOffset),
    expires: at(expiresOffset),
    reason,
    requests: [dnsRequest(path)],
    status: "pending",
    preflight_results: [],
    results: [],
  };
}

const seed = [
  pending(
    ids.approve,
    -5 * MINUTE,
    HOUR,
    "full approval reason from the stub admin server",
    "/zones/0123456789abcdef0123456789abcdef/dns_records/abcdefabcdefabcdefabcdefabcdefab",
  ),
  pending(
    ids.deny,
    -4 * MINUTE,
    HOUR,
    "second pending ticket for denial coverage",
    "/zones/0123456789abcdef0123456789abcdef/dns_records/bbcdefabcdefabcdefabcdefabcdefab",
  ),
  // Already past its expiry: a read must lazily expire it rather than serve it
  // as pending.
  pending(
    ids.overdue,
    -2 * HOUR,
    -1 * HOUR,
    "pending ticket whose TTL already elapsed",
    "/zones/0123456789abcdef0123456789abcdef/dns_records/cccdefabcdefabcdefabcdefabcdefab",
  ),
  {
    ...pending(
      ids.executed,
      -30 * MINUTE,
      HOUR,
      "already executed fixture",
      "/zones/0123456789abcdef0123456789abcdef/dns_records/dccdefabcdefabcdefabcdefabcdefab",
    ),
    status: "executed",
    preflight_results: [
      {
        index: 0,
        phase: "initial",
        checked: at(-29 * MINUTE),
        matched: true,
        expected_status: 200,
        observed_status: 200,
        expected_result_sha256: "1".repeat(64),
        observed_result_sha256: "1".repeat(64),
      },
    ],
    results: [
      {
        index: 0,
        method: "PATCH",
        path: "/zones/0123456789abcdef0123456789abcdef/dns_records/dccdefabcdefabcdefabcdefabcdefab",
        started: at(-29 * MINUTE),
        completed: at(-29 * MINUTE + 100),
        status: 200,
        ok: true,
        outcome: "succeeded",
        response: { success: true, result: { unchanged: true } },
      },
    ],
  },
  // Terminal and older than the retention window: a listing call must unlink it.
  {
    ...pending(
      ids.prunable,
      -400 * DAY,
      -400 * DAY + HOUR,
      "terminal ticket past the retention window",
      "/zones/0123456789abcdef0123456789abcdef/dns_records/eccdefabcdefabcdefabcdefabcdefab",
    ),
    status: "denied",
    denial_note: "denied long ago",
  },
  // An outcome that is genuinely unknown. It must never render as failed.
  {
    ...pending(
      ids.indeterminate,
      -20 * MINUTE,
      HOUR,
      "restart recovery left this outcome unknown",
      "/zones/0123456789abcdef0123456789abcdef/dns_records/fccdefabcdefabcdefabcdefabcdefab",
    ),
    status: "indeterminate",
    results: [
      {
        index: 0,
        method: "PATCH",
        path: "/zones/0123456789abcdef0123456789abcdef/dns_records/fccdefabcdefabcdefabcdefabcdefab",
        started: at(-19 * MINUTE),
        completed: at(-19 * MINUTE + 100),
        status: null,
        ok: false,
        outcome: "indeterminate",
        response: null,
        error: "broker restarted before the mutation outcome was known",
      },
    ],
  },
];

const tickets = new Map();
for (const ticket of seed) {
  tickets.set(ticket.id, { ...ticket, ticket_sha256: ticketSha256(ticket) });
}

let ticketListRequests = 0;
// Counted so the suite can prove a decision is submitted exactly once.
let decisionPosts = 0;

// ---------------------------------------------------------------------------
// Store behaviour
// ---------------------------------------------------------------------------

/** Expiry is lazy: it fires on every read and every decision, never on a timer. */
function expireIfNeeded(ticket) {
  if (ticket.status !== "pending") return ticket;
  if (Date.now() < Date.parse(ticket.expires)) return ticket;
  const expired = { ...ticket, status: "expired" };
  tickets.set(expired.id, expired);
  return expired;
}

/** GET /tickets is not a pure read: it expires the overdue and prunes the aged. */
function listAndMaintain(status) {
  const now = Date.now();
  const visible = [];
  for (const stored of [...tickets.values()]) {
    const ticket = expireIfNeeded(stored);
    if (
      TERMINAL.has(ticket.status) &&
      now - Date.parse(ticket.created) >= RETENTION_MS
    ) {
      tickets.delete(ticket.id);
      continue;
    }
    if (status === null || ticket.status === status) visible.push(ticket);
  }
  visible.sort((left, right) => right.created.localeCompare(left.created));
  return visible.map((ticket) => ({
    id: ticket.id,
    created: ticket.created,
    expires: ticket.expires,
    status: ticket.status,
    ticket_sha256: ticket.ticket_sha256,
    reason: ticket.reason,
    request_count: ticket.requests.length,
    result_count: ticket.results.length,
  }));
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

function json(response, status, body, headers = {}) {
  const encoded = JSON.stringify(body);
  response.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(encoded),
    ...headers,
  });
  response.end(encoded);
}

/**
 * No catch-all is registered behind the four admin routes, so an unknown path
 * or a wrong method on a known path reaches Express's finalhandler and comes
 * back as HTML. A client that assumes every non-2xx carries {"error":...} will
 * misreport its own typo.
 */
function htmlNotFound(response, method, pathname) {
  const body =
    "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" +
    "<title>Error</title>\n</head>\n<body>\n<pre>Cannot " +
    `${method} ${pathname}</pre>\n</body>\n</html>\n`;
  response.writeHead(404, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

// ---------------------------------------------------------------------------
// Gates
// ---------------------------------------------------------------------------

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
 * The order is client-visible: a request with a wrong Host and no capability
 * answers 400, not 401, and a bodyless POST from an unauthenticated client
 * answers 401, not 415. A status names the first gate that failed, never the
 * worst thing wrong with the request.
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
    json(response, 401, { error: "unauthorized" }, { "WWW-Authenticate": "Bearer" });
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

// ---------------------------------------------------------------------------
// Body and schemas
// ---------------------------------------------------------------------------

class PayloadTooLargeError extends Error {}
class InvalidJsonError extends Error {}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > BODY_LIMIT_BYTES) throw new PayloadTooLargeError();
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
  // express.json({ strict: true }) accepts only objects and arrays.
  if (parsed === null || typeof parsed !== "object") throw new InvalidJsonError();
  return parsed;
}

const DIGEST_PATTERN = /^[a-f0-9]{64}$/;

function parseDecision(action, body) {
  const issues = [];
  const allowed = action === "deny" ? ["ticket_sha256", "note"] : ["ticket_sha256"];
  for (const key of Object.keys(body)) {
    if (!allowed.includes(key)) {
      issues.push({
        code: "unrecognized_keys",
        path: [],
        message: `Unrecognized key: "${key}"`,
      });
    }
  }
  if (typeof body.ticket_sha256 !== "string") {
    issues.push({
      code: "invalid_type",
      path: ["ticket_sha256"],
      message: "Invalid input: expected string",
    });
  } else if (!DIGEST_PATTERN.test(body.ticket_sha256)) {
    issues.push({
      code: "invalid_format",
      path: ["ticket_sha256"],
      message: "ticket_sha256 must be 64 lowercase hex digits",
    });
  }
  let note;
  if (action === "deny" && body.note !== undefined) {
    if (typeof body.note !== "string") {
      issues.push({
        code: "invalid_type",
        path: ["note"],
        message: "Invalid input: expected string",
      });
    } else {
      note = body.note.trim();
      if (note.length < 1 || note.length > 4000) {
        issues.push({
          code: "too_small",
          path: ["note"],
          message: "note must be 1..4000 characters after trimming",
        });
      }
    }
  }
  if (issues.length > 0) return { issues };
  return { digest: body.ticket_sha256, note };
}

// ---------------------------------------------------------------------------
// Decisions
// ---------------------------------------------------------------------------

function executeApproval(ticket) {
  const checked = new Date().toISOString();
  const executed = {
    ...ticket,
    status: "executed",
    preflight_results: ticket.requests.flatMap((stored, index) =>
      ["initial", "immediate"].map((phase) => ({
        index,
        phase,
        checked,
        matched: true,
        expected_status: stored.precondition.expect.status,
        observed_status: stored.precondition.expect.status,
        expected_result_sha256: stored.precondition.expect.result_sha256,
        observed_result_sha256: stored.precondition.expect.result_sha256,
      })),
    ),
    results: ticket.requests.map((stored, index) => ({
      index,
      method: stored.method,
      path: stored.path,
      started: checked,
      completed: checked,
      status: 200,
      ok: true,
      outcome: "succeeded",
      response: { success: true, result: { unchanged: true } },
    })),
  };
  tickets.set(executed.id, executed);
  return executed;
}

function decide(action, ticket, parsed, response) {
  // The digest is checked before the state machine, and it guards cross-ticket
  // replay and tampering rather than a concurrent decision: the five immutable
  // fields never change, so a ticket decided elsewhere still matches.
  if (parsed.digest !== ticket.ticket_sha256) {
    return json(response, 409, {
      error: `ticket ${ticket.id} digest does not match the reviewed immutable payload`,
    });
  }
  if (ticket.status !== "pending") {
    return json(response, 409, {
      error: `ticket ${ticket.id} cannot transition from ${ticket.status} to ${
        action === "approve" ? "approved" : "denied"
      }`,
    });
  }
  if (action === "approve") {
    // Approval executes synchronously, so a 200 from approve is always
    // terminal. A 200 carrying "approved" or "executing" cannot occur.
    return json(response, 200, executeApproval(ticket));
  }
  const denied = { ...ticket, status: "denied" };
  // The note comes back under a different name.
  if (parsed.note !== undefined) denied.denial_note = parsed.note;
  tickets.set(denied.id, denied);
  return json(response, 200, denied);
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

const TICKET_ID = /^t_\d{8}T\d{6}\.\d{3}Z_[a-f0-9]{12}$/;

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  const pathname = url.pathname;

  // Test scaffolding, outside the admin contract and outside the gates. The
  // real broker serves neither route.
  if (request.method === "GET" && pathname === "/health") {
    return json(response, 200, { ok: true });
  }
  if (request.method === "GET" && pathname === "/__stats") {
    return json(response, 200, {
      ticket_list_requests: ticketListRequests,
      decision_posts: decisionPosts,
      ids,
      ticket_count: tickets.size,
    });
  }

  // Set ahead of the gates so failures carry it too.
  response.setHeader("Cache-Control", "no-store");
  if (!runGates(request, response)) return;

  if (request.method === "GET" && pathname === "/tickets") {
    ticketListRequests += 1;
    const status = url.searchParams.get("status");
    return json(response, 200, { tickets: listAndMaintain(status) });
  }

  const detail = pathname.match(/^\/tickets\/([^/]+)$/);
  if (request.method === "GET" && detail) {
    const id = decodeURIComponent(detail[1]);
    // An unknown or malformed id is a 404, not a schema error.
    if (!TICKET_ID.test(id) || !tickets.has(id)) {
      return json(response, 404, { error: `ticket not found: ${id}` });
    }
    // GET /tickets/:id expires but never prunes.
    return json(response, 200, expireIfNeeded(tickets.get(id)));
  }

  const action = pathname.match(/^\/tickets\/([^/]+)\/(approve|deny)$/);
  if (request.method === "POST" && action) {
    decisionPosts += 1;
    const id = decodeURIComponent(action[1]);
    let body;
    try {
      body = await readJsonBody(request);
    } catch (error) {
      if (error instanceof PayloadTooLargeError) {
        // PayloadTooLargeError matches no branch of the broker's error handler,
        // so it falls through to 500 rather than the 413 a reader expects.
        return json(response, 500, { error: "internal server error" });
      }
      return json(response, 400, { error: "invalid JSON body" });
    }

    const parsed = parseDecision(action[2], body);
    if (parsed.issues) {
      return json(response, 400, { error: "invalid request", issues: parsed.issues });
    }
    if (!TICKET_ID.test(id) || !tickets.has(id)) {
      return json(response, 404, { error: `ticket not found: ${id}` });
    }
    return decide(action[2], expireIfNeeded(tickets.get(id)), parsed, response);
  }

  return htmlNotFound(response, request.method ?? "GET", pathname);
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`ready ${port}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
