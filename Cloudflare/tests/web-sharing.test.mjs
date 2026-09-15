import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, test } from "node:test";

import worker from "../worker.mjs";

const TOKEN = "test-sync-token";
const BASE = "https://sync.example.com";
const SOURCE_ID = "11111111-2222-3333-8444-555555555555";
const OTHER_SOURCE_ID = "AAAAAAAA-BBBB-CCCC-8DDD-EEEEEEEEEEEE";
const DAY_MS = 24 * 60 * 60 * 1000;

function makeEnv() {
  const db = new MemoryD1();
  return {
    DB: db,
    AUDIO: new MemoryR2(),
    SYNC_TOKEN: TOKEN,
    __db: db,
  };
}

function authHeaders(extra = {}) {
  return { Authorization: `Bearer ${TOKEN}`, ...extra };
}

async function request(env, pathOrUrl, init = {}) {
  const url = pathOrUrl.startsWith("http") ? pathOrUrl : `${BASE}${pathOrUrl}`;
  const headers = new Headers(init.headers ?? {});
  return worker.fetch(new Request(url, { ...init, headers }), env);
}

async function readJson(response) {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    assert.fail(`expected JSON body, got ${text}`);
  }
}

async function publishShare(env, overrides = {}) {
  const response = await request(env, `/v1/shares/${overrides.sourceID ?? SOURCE_ID}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({
      title: overrides.title ?? "Project <Planning>",
      markdown: overrides.markdown ?? "# Minutes\n\n- Ship <soon>\n- [unsafe](https://example.com)",
    }),
  });
  if (response.status !== 200) {
    assert.fail(`expected 200, got ${response.status}: ${await response.text()}`);
  }
  return readJson(response);
}

function tokenFromUrl(url) {
  return new URL(url).pathname.slice("/s/".length);
}

function sha256Hex(text) {
  return createHash("sha256").update(text).digest("hex");
}

class MemoryD1 {
  constructor() {
    this.shareRows = new Map();
    this.statements = [];
    this.failNextRun = false;
    this.pauseInsertRuns = false;
    this.insertRunWaiters = [];
  }

  prepare(sql) {
    return new MemoryStatement(this, sql);
  }
}

class MemoryStatement {
  constructor(db, sql) {
    this.db = db;
    this.sql = sql;
    this.values = [];
  }

  bind(...values) {
    this.values = values;
    return this;
  }

  async first() {
    if (this.sql.includes("FROM web_shares") && this.sql.includes("LIMIT 1")) {
      return { ok: 1 };
    }
    if (this.sql.includes("FROM web_shares") && this.sql.includes("source_id = ?")) {
      const row = this.db.shareRows.get(this.values[0]);
      if (this.sql.includes("object_key = ?")) {
        const [, objectKey, tokenHash, publicToken, now] = this.values;
        if (!row || row.object_key !== objectKey || row.expires_at <= now
            || (row.token_hash !== tokenHash && row.public_token !== publicToken)) return null;
      }
      return row ? { ...row } : null;
    }
    if (this.sql.includes("FROM web_shares") && this.sql.includes("token_hash = ?")) {
      const [tokenHash, publicToken, now] = this.values;
      const row = [...this.db.shareRows.values()].find((candidate) =>
        (candidate.token_hash === tokenHash || candidate.public_token === publicToken) && candidate.expires_at > now,
      );
      return row ? { ...row } : null;
    }
    throw new Error(`unexpected first SQL: ${this.sql}`);
  }

  async run() {
    this.db.statements.push({ sql: this.sql, values: this.values });
    if (this.sql.includes("INSERT INTO web_shares")) {
      if (this.db.failNextRun) {
        this.db.failNextRun = false;
        throw new Error("simulated D1 failure");
      }
      if (this.db.pauseInsertRuns) {
        await new Promise((resolve) => {
          this.db.insertRunWaiters.push(resolve);
          if (this.db.insertRunWaiters.length === 2) {
            const waiters = this.db.insertRunWaiters.splice(0);
            this.db.pauseInsertRuns = false;
            for (const waiter of waiters) {
              waiter();
            }
          }
        });
      }
      const [source_id, token_hash, public_token, object_key, title, created_at, expires_at] = this.values;
      for (const row of this.db.shareRows.values()) {
        if (row.source_id !== source_id && row.token_hash === token_hash) {
          throw new Error("UNIQUE constraint failed: web_shares.token_hash");
        }
        if (row.source_id !== source_id && row.public_token === public_token) {
          throw new Error("UNIQUE constraint failed: web_shares.public_token");
        }
      }
      this.db.shareRows.set(source_id, {
        source_id,
        token_hash,
        public_token,
        object_key,
        title,
        created_at,
        expires_at,
      });
      return { success: true };
    }
    if (this.sql.includes("UPDATE web_shares SET public_token")) {
      const [token, sourceID, tokenHash, now] = this.values;
      const row = this.db.shareRows.get(sourceID);
      if (row && row.token_hash === tokenHash && row.public_token == null && row.expires_at > now) {
        row.public_token = token;
      }
      return { success: true };
    }
    if (this.sql.includes("DELETE FROM web_shares")) {
      this.db.shareRows.delete(this.values[0]);
      return { success: true };
    }
    throw new Error(`unexpected run SQL: ${this.sql}`);
  }
}

class MemoryR2 {
  constructor() {
    this.objects = new Map();
    this.failNextPut = false;
    this.returnNullNextPut = false;
  }

  async put(key, value, options = {}) {
    if (this.failNextPut) {
      this.failNextPut = false;
      throw new Error("simulated R2 failure");
    }
    if (this.returnNullNextPut) {
      this.returnNullNextPut = false;
      return null;
    }
    if (options.onlyIf?.etagDoesNotMatch === "*" && this.objects.has(key)) {
      return null;
    }
    const body = await new Response(value).arrayBuffer();
    this.objects.set(key, {
      body,
      httpMetadata: options.httpMetadata ?? {},
    });
    return { key };
  }

  async get(key) {
    const object = this.objects.get(key);
    if (!object) {
      return null;
    }
    return {
      body: object.body.slice(0),
      httpMetadata: object.httpMetadata,
      size: object.body.byteLength,
    };
  }

  async head(key) {
    return this.objects.get(key) ?? null;
  }
}

describe("Cloudflare web sharing", () => {
  test("keeps share management private while public token pages require no credentials", async () => {
    const env = makeEnv();

    const unauthorized = await request(env, `/v1/shares/${SOURCE_ID}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Nope", markdown: "Secret" }),
    });
    assert.equal(unauthorized.status, 401);

    const created = await publishShare(env);
    const publicPage = await request(env, created.url);
    const privateApi = await request(env, "/v1/recordings");

    assert.equal(publicPage.status, 200);
    assert.equal(publicPage.headers.get("Content-Type"), "text/html; charset=utf-8");
    assert.equal(publicPage.headers.get("Cache-Control"), "no-store");
    assert.equal(publicPage.headers.get("X-Robots-Tag"), "noindex, nofollow, noarchive");
    assert.equal(privateApi.status, 401);
  });

  test("keeps every /s namespace route public without bearer challenges", async () => {
    const env = makeEnv();
    const created = await publishShare(env);
    const head = await request(env, created.url, { method: "HEAD" });
    const post = await request(env, new URL(created.url).pathname, { method: "POST" });
    const root = await request(env, "/s");
    const trailingSlash = await request(env, `${new URL(created.url).pathname}/`);

    assert.equal(head.status, 200);
    assert.equal(await head.text(), "");
    assert.equal(head.headers.get("Content-Type"), "text/html; charset=utf-8");
    for (const response of [post, root, trailingSlash]) {
      assert.equal(response.status, 404);
      assert.equal(response.headers.get("WWW-Authenticate"), null);
      assert.equal(response.headers.get("Cache-Control"), "no-store");
      assert.match(await response.text(), /공유를 찾을 수 없습니다/);
    }
  });

  test("publishes an escaped seven-day snapshot and privately persists its retrievable token", async () => {
    const env = makeEnv();
    const before = Date.now();
    const created = await publishShare(env, {
      title: "  Project <Planning>  ",
      markdown: "# <Kickoff>\n\nParagraph with <script>alert(1)</script>.\n\n```html\n<b>raw</b>\n```",
    });
    const after = Date.now();
    const token = tokenFromUrl(created.url);
    const row = env.__db.shareRows.get(SOURCE_ID);
    const page = await request(env, created.url);
    const html = await page.text();

    assert.match(token, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(row.token_hash, sha256Hex(token));
    assert.equal(row.public_token, token);
    assert.equal(row.title, "Project <Planning>");
    assert.equal(row.expires_at, created.expiresAt);
    assert.ok(created.expiresAt >= before + 7 * DAY_MS);
    assert.ok(created.expiresAt <= after + 7 * DAY_MS + 1000);
    assert.equal(page.status, 200);
    assert.match(html, /Project &lt;Planning&gt;/);
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
    assert.match(html, /&lt;b&gt;raw&lt;\/b&gt;/);
    assert.doesNotMatch(html, /<script/);
    assert.doesNotMatch(html, /href="https:\/\/example.com"/);
    assert.equal(page.headers.get("Content-Security-Policy"), "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  });

  test("renders Korean public pages with safe inline formatting and resilient wrapping", async () => {
    const env = makeEnv();
    const created = await publishShare(env, {
      title: "9월22일 " + "긴제목".repeat(40),
      markdown: "회의 **중요** 내용과 `inline <code>` 입니다.\n\n```md\n**not bold** <tag>\n```",
    });

    const page = await request(env, created.url);
    const html = await page.text();

    assert.equal(page.status, 200);
    assert.match(html, /<html lang="ko">/);
    assert.match(html, /AI-NoteTaker/);
    assert.match(html, /공유된 회의록입니다\./);
    assert.match(html, /한국 시간/);
    assert.match(html, /만료/);
    assert.match(html, /overflow-wrap:anywhere/);
    assert.match(html, /word-break:break-word/);
    assert.match(html, /\.meta\{[^}]*word-break:keep-all/);
    assert.match(html, /회의 <strong>중요<\/strong> 내용과 <code>inline &lt;code&gt;<\/code> 입니다\./);
    assert.match(html, /<code>\*\*not bold\*\* &lt;tag&gt;<\/code>/);
  });

  test("renders long mixed Unicode paragraphs with escaped text and inline formatting intact", async () => {
    const env = makeEnv();
    const longPlain = "긴문장<&>\"'🙂".repeat(2000);
    const created = await publishShare(env, {
      title: "긴 본문",
      markdown: `${longPlain} **굵게 <표시>** 중간 \`코드 <tag> & value\` 끝`,
    });

    const page = await request(env, created.url);
    const html = await page.text();

    assert.equal(page.status, 200);
    assert.match(html, /긴문장&lt;&amp;&gt;&quot;&#39;🙂긴문장/);
    assert.match(html, /<strong>굵게 &lt;표시&gt;<\/strong>/);
    assert.match(html, /<code>코드 &lt;tag&gt; &amp; value<\/code>/);
    assert.doesNotMatch(html, /<표시>|<tag>/);
  });

  test("renders sparse wide tables without synthesizing missing cells", async () => {
    const env = makeEnv();
    const columns = 2000;
    const rows = 200;
    const header = Array.from({ length: columns }, (_, index) => `H${index}`).join("|");
    const divider = Array.from({ length: columns }, () => "---").join("|");
    const body = Array.from({ length: rows }, (_, index) => `R${index}|`).join("\n");
    const created = await publishShare(env, {
      title: "Wide table",
      markdown: `${header}\n${divider}\n${body}`,
    });

    const page = await request(env, created.url);
    const html = await page.text();
    const tdCount = html.match(/<td>/g)?.length ?? 0;
    const thCount = html.match(/<th>/g)?.length ?? 0;

    assert.equal(page.status, 200);
    assert.equal(thCount, columns);
    assert.equal(tdCount, rows);
    assert.match(html, /<td>R199<\/td>/);
  });

  test("returns the existing URL only in authenticated status without snapshot content or object keys", async () => {
    const env = makeEnv();
    const created = await publishShare(env);

    const active = await request(env, `/v1/shares/${SOURCE_ID}`, { headers: authHeaders() });
    const inactive = await request(env, `/v1/shares/${OTHER_SOURCE_ID}`, { headers: authHeaders() });
    const activeBody = await readJson(active);

    assert.equal(active.status, 200);
    assert.deepEqual(activeBody, { active: true, url: created.url, expiresAt: created.expiresAt });
    assert.deepEqual(await readJson(inactive), { active: false });
  });

  test("replacement invalidates the previous token without deleting snapshot objects", async () => {
    const env = makeEnv();
    const first = await publishShare(env, { markdown: "First body" });
    const firstToken = tokenFromUrl(first.url);
    const firstKey = env.__db.shareRows.get(SOURCE_ID).object_key;
    const second = await publishShare(env, { markdown: "Second body" });
    const secondToken = tokenFromUrl(second.url);
    const secondKey = env.__db.shareRows.get(SOURCE_ID).object_key;

    const oldPage = await request(env, first.url);
    const newPage = await request(env, second.url);

    assert.notEqual(firstToken, secondToken);
    assert.notEqual(firstKey, secondKey);
    assert.equal(oldPage.status, 404);
    assert.equal(newPage.status, 200);
    assert.equal(await env.AUDIO.get(firstKey) !== null, true);
    assert.equal(await env.AUDIO.get(secondKey) !== null, true);
    assert.match(await newPage.text(), /Second body/);
  });

  test("interleaved publications keep the winning snapshot readable without deleting objects", async () => {
    const env = makeEnv();
    env.__db.pauseInsertRuns = true;

    const [left, right] = await Promise.all([
      publishShare(env, { markdown: "Concurrent left" }),
      publishShare(env, { markdown: "Concurrent right" }),
    ]);
    const row = env.__db.shareRows.get(SOURCE_ID);
    const rowSnapshot = JSON.parse(await new Response((await env.AUDIO.get(row.object_key)).body).text());
    const leftPage = await request(env, left.url);
    const rightPage = await request(env, right.url);
    const activePages = [leftPage, rightPage].filter((response) => response.status === 200);

    assert.equal(env.__db.shareRows.size, 1);
    assert.equal(env.AUDIO.objects.size, 2);
    assert.equal(activePages.length, 1);
    assert.equal(await env.AUDIO.get([...env.AUDIO.objects.keys()][0]) !== null, true);
    assert.equal(await env.AUDIO.get([...env.AUDIO.objects.keys()][1]) !== null, true);
    assert.match(await activePages[0].text(), new RegExp(rowSnapshot.markdown));
  });

  test("delete is idempotent and revokes the public token immediately", async () => {
    const env = makeEnv();
    const created = await publishShare(env);

    const firstDelete = await request(env, `/v1/shares/${SOURCE_ID}`, {
      method: "DELETE",
      headers: authHeaders(),
    });
    const secondDelete = await request(env, `/v1/shares/${SOURCE_ID}`, {
      method: "DELETE",
      headers: authHeaders(),
    });
    const page = await request(env, created.url);
    const status = await request(env, `/v1/shares/${SOURCE_ID}`, { headers: authHeaders() });

    assert.equal(firstDelete.status, 204);
    assert.equal(secondDelete.status, 204);
    assert.equal(page.status, 404);
    assert.deepEqual(await readJson(status), { active: false });
  });

  test("expired, missing, malformed, and revoked tokens share the same generic no-store 404", async () => {
    const env = makeEnv();
    const created = await publishShare(env);
    env.__db.shareRows.get(SOURCE_ID).expires_at = Date.now() - 1;

    for (const target of [created.url, `${BASE}/s/not-valid!`, `${BASE}/s/bad/path`, `${BASE}/s/${"A".repeat(43)}`]) {
      const response = await request(env, target);
      const body = await response.text();
      assert.equal(response.status, 404);
      assert.equal(response.headers.get("Cache-Control"), "no-store");
      assert.equal(response.headers.get("X-Robots-Tag"), "noindex, nofollow, noarchive");
      assert.match(body, /공유를 찾을 수 없습니다/);
      assert.match(body, /<html lang="ko">/);
      assert.doesNotMatch(body, /sync-token|11111111|Secret|source/i);
    }
  });

  test("rejects malformed share requests before changing stored state", async () => {
    const env = makeEnv();
    const valid = await publishShare(env);
    const validToken = tokenFromUrl(valid.url);
    const cases = [
      { path: `/v1/shares/${SOURCE_ID.toLowerCase()}`, body: { title: "Lowercase path", markdown: "Accepted after normalization" }, status: 200 },
      { path: "/v1/shares/not-a-uuid", body: { title: "Bad", markdown: "No" }, status: 400 },
      { path: `/v1/shares/${SOURCE_ID}`, body: { title: "", markdown: "No" }, status: 400 },
      { path: `/v1/shares/${SOURCE_ID}`, body: { title: "x".repeat(301), markdown: "No" }, status: 400 },
      { path: `/v1/shares/${SOURCE_ID}`, body: { title: "OK", markdown: "" }, status: 400 },
      { path: `/v1/shares/${SOURCE_ID}`, body: { title: "OK", markdown: "No", transcript: "secret" }, status: 400 },
      { path: `/v1/shares/${SOURCE_ID}`, body: { title: "OK", markdown: "x".repeat(1024 * 1024 + 1) }, status: 413 },
    ];

    for (const item of cases) {
      const response = await request(env, item.path, {
        method: "PUT",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify(item.body),
      });
      assert.equal(response.status, item.status);
    }

    assert.notEqual(env.__db.shareRows.get(SOURCE_ID).token_hash, sha256Hex(validToken));
    assert.equal(env.__db.shareRows.size, 1);
  });

  test("preserves the existing live share when the R2 snapshot write fails", async () => {
    const env = makeEnv();
    const first = await publishShare(env, { markdown: "Still live" });
    const firstRow = { ...env.__db.shareRows.get(SOURCE_ID) };
    env.AUDIO.failNextPut = true;

    const failed = await request(env, `/v1/shares/${SOURCE_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ title: "Broken", markdown: "Should not replace" }),
    });
    const oldPage = await request(env, first.url);

    assert.equal(failed.status, 500);
    assert.deepEqual(env.__db.shareRows.get(SOURCE_ID), firstRow);
    assert.equal(oldPage.status, 200);
    assert.match(await oldPage.text(), /Still live/);
  });

  test("preserves the existing live share when the D1 authorization write fails", async () => {
    const env = makeEnv();
    const first = await publishShare(env, { markdown: "D1 old share" });
    const firstRow = { ...env.__db.shareRows.get(SOURCE_ID) };
    env.__db.failNextRun = true;

    const failed = await request(env, `/v1/shares/${SOURCE_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ title: "Broken D1", markdown: "Should not authorize" }),
    });
    const oldPage = await request(env, first.url);

    assert.equal(failed.status, 500);
    assert.deepEqual(env.__db.shareRows.get(SOURCE_ID), firstRow);
    assert.equal(oldPage.status, 200);
    assert.match(await oldPage.text(), /D1 old share/);
    assert.equal(env.AUDIO.objects.size, 2);
  });

  test("does not publish a D1 row when the R2 conditional snapshot write conflicts", async () => {
    const env = makeEnv();
    env.AUDIO.returnNullNextPut = true;

    const failed = await request(env, `/v1/shares/${SOURCE_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ title: "R2 conflict", markdown: "Should not publish" }),
    });

    assert.equal(failed.status, 500);
    assert.equal(env.__db.shareRows.size, 0);
    assert.equal(env.AUDIO.objects.size, 0);
  });

  test("generated web_shares migration enforces one active row per source and unique token hashes", () => {
    const migration = readFileSync(new URL("../migrations/0006_web_shares.sql", import.meta.url), "utf8");
    const child = spawnSync(
      process.env.PYTHON ?? "python3",
      [
        "-c",
        `
import sqlite3
conn = sqlite3.connect(':memory:')
conn.executescript(open(0).read())
conn.execute(
  'INSERT INTO web_shares (source_id, token_hash, object_key, title, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)',
  ('A', 'hash-a', 'key-a', 'Title A', 1, 2),
)
conn.execute(
  'INSERT INTO web_shares (source_id, token_hash, object_key, title, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(source_id) DO UPDATE SET token_hash = excluded.token_hash, object_key = excluded.object_key, title = excluded.title, created_at = excluded.created_at, expires_at = excluded.expires_at',
  ('A', 'hash-b', 'key-b', 'Title B', 3, 4),
)
try:
  conn.execute(
    'INSERT INTO web_shares (source_id, token_hash, object_key, title, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)',
    ('B', 'hash-b', 'key-c', 'Title C', 5, 6),
  )
  raise AssertionError('token_hash uniqueness was not enforced')
except sqlite3.IntegrityError:
  pass
row = conn.execute('SELECT token_hash, object_key, title, created_at, expires_at FROM web_shares WHERE source_id = ?', ('A',)).fetchone()
assert row == ('hash-b', 'key-b', 'Title B', 3, 4), row
print('web_shares migration ok')
`,
      ],
      { encoding: "utf8", input: migration },
    );

    assert.equal(child.status, 0, child.stderr || child.stdout);
    assert.match(child.stdout, /web_shares migration ok/);
  });
});
