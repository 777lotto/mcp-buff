const http = require("node:http");

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("usage: node scripts/stub-admin-server.js PORT");
}

const ids = {
  approve: "t_20260820T180000.000Z_000000000001",
  deny: "t_20260820T180100.000Z_000000000002",
  executed: "t_20260820T170000.000Z_000000000003",
};

function pending(id, created, reason, path) {
  return {
    id,
    created,
    reason,
    requests: [
      {
        method: "PATCH",
        path,
        body: { comment: "stub no-op", metadata: { reviewed: true } },
      },
    ],
    status: "pending",
    expires: "2026-08-21T18:00:00.000Z",
    results: [],
  };
}

const tickets = new Map([
  [
    ids.approve,
    pending(
      ids.approve,
      "2026-08-20T18:00:00.000Z",
      "full approval reason from the stub admin server",
      "/zones/example-zone/dns_records/example-record",
    ),
  ],
  [
    ids.deny,
    pending(
      ids.deny,
      "2026-08-20T18:01:00.000Z",
      "second pending ticket for denial coverage",
      "/accounts/example-account/workers/scripts/example/settings",
    ),
  ],
  [
    ids.executed,
    {
      id: ids.executed,
      created: "2026-08-20T17:00:00.000Z",
      reason: "already executed fixture",
      requests: [
        {
          method: "POST",
          path: "/accounts/example-account/storage/kv/namespaces",
          body: { title: "example-cache" },
        },
      ],
      status: "executed",
      expires: "2026-08-21T17:00:00.000Z",
      results: [
        {
          index: 0,
          method: "POST",
          path: "/accounts/example-account/storage/kv/namespaces",
          started: "2026-08-20T17:01:00.000Z",
          completed: "2026-08-20T17:01:00.100Z",
          status: 200,
          ok: true,
          response: { success: true, result: { id: "stub-result" } },
        },
      ],
    },
  ],
]);
let ticketListRequests = 0;

function summary(ticket) {
  return {
    id: ticket.id,
    created: ticket.created,
    expires: ticket.expires,
    status: ticket.status,
    reason: ticket.reason,
    request_count: ticket.requests.length,
    result_count: ticket.results.length,
  };
}

function json(response, status, body) {
  const encoded = JSON.stringify(body);
  response.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(encoded),
  });
  response.end(encoded);
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  if (request.method === "GET" && url.pathname === "/health") {
    return json(response, 200, { ok: true });
  }
  if (request.method === "GET" && url.pathname === "/__stats") {
    return json(response, 200, { ticket_list_requests: ticketListRequests });
  }
  if (request.method === "GET" && url.pathname === "/tickets") {
    ticketListRequests += 1;
    const status = url.searchParams.get("status");
    const visible = [...tickets.values()].filter(
      (ticket) => status === null || ticket.status === status,
    );
    return json(response, 200, { tickets: visible.map(summary) });
  }

  const detail = url.pathname.match(/^\/tickets\/(t_[A-Za-z0-9_.-]+)$/);
  if (request.method === "GET" && detail) {
    const ticket = tickets.get(detail[1]);
    return ticket
      ? json(response, 200, ticket)
      : json(response, 404, { error: "ticket not found" });
  }

  const action = url.pathname.match(
    /^\/tickets\/(t_[A-Za-z0-9_.-]+)\/(approve|deny)$/,
  );
  if (request.method === "POST" && action) {
    const ticket = tickets.get(action[1]);
    if (!ticket) return json(response, 404, { error: "ticket not found" });
    if (ticket.status !== "pending") {
      return json(response, 409, {
        error: `ticket ${ticket.id} cannot transition from ${ticket.status}`,
      });
    }

    if (action[2] === "approve") {
      ticket.status = "executed";
      ticket.results = ticket.requests.map((stored, index) => ({
        index,
        method: stored.method,
        path: stored.path,
        started: "2026-08-20T18:05:00.000Z",
        completed: "2026-08-20T18:05:00.100Z",
        status: 200,
        ok: true,
        response: { success: true, result: { unchanged: true } },
      }));
      return json(response, 200, ticket);
    }

    const body = await readJson(request);
    ticket.status = "denied";
    if (typeof body.note === "string" && body.note.length > 0) {
      ticket.denial_note = body.note;
    }
    return json(response, 200, ticket);
  }

  json(response, 404, { error: "not found" });
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`ready ${port}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
