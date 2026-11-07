import assert from "node:assert/strict";
import { test } from "node:test";

import worker from "./worker.js";

// Fakes GitHub, recording what the Worker asks of it.
function setup({ existing = null, newThisHour = 0, comments = 0 } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url, method: init.method, body });
    let reply = {};
    if (url.includes("/search/issues") && url.includes("fp-")) {
      reply = { items: existing ? [{ ...existing, comments }] : [] };
    } else if (url.includes("/search/issues")) {
      reply = { total_count: newThisHour };
    } else if (init.method === "POST") {
      reply = { number: 42, html_url: "https://github.com/x/y/issues/42" };
    }
    return new Response(JSON.stringify(reply), { status: 200 });
  };
  const env = {
    GITHUB_TOKEN: "t",
    REPORT_LIMITER: { limit: async () => ({ success: true }) },
  };
  return { calls, env };
}

const post = (body, path = "/report") =>
  new Request(`https://relay.test${path}`, {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

const good = { description: "it broke", version: "0.2.1", platform: "Ubuntu" };

test("files an issue on Tala's repo with the setup facts", async () => {
  const { calls, env } = setup();
  const r = await worker.fetch(
    post({ ...good, facts: "Tray host: yes\nServer: Nextcloud 34", log: "line" }),
    env,
  );
  assert.equal(r.status, 201);
  const issue = calls.find((c) => c.url.endsWith("/repos/kz6fittycent/tala/issues"));
  assert.ok(issue);
  assert.deepEqual(issue.body.labels, ["user-report"]);
  assert.match(issue.body.body, /### Setup/);
  assert.match(issue.body.body, /- Tray host: yes/);
  assert.match(issue.body.body, /- Server: Nextcloud 34/);
  assert.match(issue.body.body, /<summary>Log<\/summary>/);
});

test("a repeat crash becomes a comment on the open issue", async () => {
  const { calls, env } = setup({
    existing: { number: 7, html_url: "https://github.com/x/y/issues/7" },
  });
  const r = await worker.fetch(post({ ...good, fingerprint: "27c8dcf0f79a" }), env);
  assert.equal(r.status, 200);
  assert.equal((await r.json()).duplicate, true);
  assert.ok(calls.some((c) => c.url.endsWith("/issues/7/comments")));
  assert.ok(!calls.some((c) => c.url.endsWith("/tala/issues")));
});

test("user text can't ping anyone, close issues or inject links", async () => {
  const { calls, env } = setup();
  await worker.fetch(
    post({ ...good, description: "@you fixes #12 [x](http://e.test)", facts: "@you" }),
    env,
  );
  const body = calls.find((c) => c.url.endsWith("/tala/issues")).body.body;
  assert.ok(!body.includes("@you"));
  assert.ok(!body.includes("#12"));
  assert.ok(!body.includes("](http"));
});

test("bad reports are refused before reaching GitHub", async () => {
  for (const bad of [
    "not json",
    { description: "x" },
    { ...good, facts: 5 },
    { ...good, facts: "x".repeat(4001) },
    { ...good, description: "x".repeat(5001) },
    { ...good, fingerprint: "NOT-HEX" },
  ]) {
    const { calls, env } = setup();
    const r = await worker.fetch(post(bad), env);
    assert.equal(r.status, 400, JSON.stringify(bad).slice(0, 40));
    assert.equal(calls.length, 0);
  }
});

test("the hourly cap holds", async () => {
  const { env } = setup({ newThisHour: 10 });
  assert.equal((await worker.fetch(post(good), env)).status, 503);
});

test("only POST /report is served", async () => {
  const { env } = setup();
  assert.equal((await worker.fetch(post(good, "/other"), env)).status, 404);
  const get = new Request("https://relay.test/report");
  assert.equal((await worker.fetch(get, env)).status, 405);
});
