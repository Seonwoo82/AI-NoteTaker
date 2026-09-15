import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import worker from "../worker.mjs";

const BASE = "https://sync.example.com";
const TOKEN = "synthetic-share-persistence-auth";
const SOURCE = "11111111-2222-3333-8444-555555555555";
const OTHER = "AAAAAAAA-BBBB-CCCC-8DDD-EEEEEEEEEEEE";
const PATH = `/v1/shares/${SOURCE}`;
const migrationURL = new URL("../migrations/0007_persistent_share_urls.sql", import.meta.url);
const python = `import json,sqlite3,sys
x=json.load(sys.stdin)
c=sqlite3.connect(x['path']);c.row_factory=sqlite3.Row
if x.get('script'): c.executescript(x['sql']); rows=[]
else: rows=[dict(r) for r in c.execute(x['sql'],x.get('values',[]))]
c.commit(); print(json.dumps(rows))`;

// Same stdlib SQLite adapter used by the other Worker integration suites.
// Hooks pause network/database boundaries; all authorization SQL executes for real.
function database(path, hooks = {}) {
  const execute = (sql, values = [], script = false) => {
    const result = spawnSync(process.env.PYTHON ?? "python3", ["-c", python], {
      input: JSON.stringify({ path, sql, values, script }), encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  return {
    execute,
    prepare(sql) {
      let values = [];
      return {
        bind(...next) { values = next; return this; },
        async first() { return execute(sql, values)[0] ?? null; },
        async run() {
          await hooks.beforeRun?.(sql, values);
          execute(sql, values);
          return { success: true };
        },
      };
    },
  };
}

function fixture(t, { persistence = true } = {}) {
  const folder = mkdtempSync(join(tmpdir(), "web-share-persistence-"));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  const path = join(folder, "test.sqlite");
  const hooks = {};
  const DB = database(path, hooks);
  for (const name of readdirSync(new URL("../migrations/", import.meta.url)).sort()) {
    if (!persistence && name.startsWith("0007_")) continue;
    DB.execute(readFileSync(new URL(`../migrations/${name}`, import.meta.url), "utf8"), [], true);
  }
  const objects = new Map();
  const AUDIO = {
    async put(key, value) { objects.set(key, new Uint8Array(value)); return { key }; },
    async get(key) {
      await hooks.beforeObjectGet?.();
      const body = objects.get(key);
      return body ? { body } : null;
    },
    async head() { return null; },
  };
  return { DB, AUDIO, SYNC_TOKEN: TOKEN, hooks, path, objects };
}

function request(env, path = PATH, { auth = true, method = "GET", body } = {}) {
  return worker.fetch(new Request(new URL(path, BASE), {
    method,
    headers: { ...(auth ? { Authorization: `Bearer ${TOKEN}` } : {}), "Content-Type": "application/json" },
    ...(body ? { body: JSON.stringify(body) } : {}),
  }), env);
}

async function status(env) {
  const response = await request(env);
  assert.equal(response.status, 200);
  return response.json();
}

async function publish(env, title = "Persisted snapshot") {
  const response = await request(env, PATH, { method: "PUT", body: { title, markdown: "Unchanged minutes" } });
  assert.equal(response.status, 200);
  return response.json();
}

async function legacy(env) {
  const created = await publish(env);
  env.DB.execute("UPDATE web_shares SET public_token = NULL WHERE source_id = ?", [SOURCE]);
  return created;
}

function row(env) {
  return env.DB.execute("SELECT * FROM web_shares WHERE source_id = ?", [SOURCE])[0] ?? null;
}

function pauseOnce(hooks, key, matches = () => true) {
  let release;
  let announce;
  const arrived = new Promise((resolve) => { announce = resolve; });
  const paused = new Promise((resolve) => { release = resolve; });
  hooks[key] = async (...args) => {
    if (!matches(...args)) return;
    delete hooks[key];
    announce();
    await paused;
  };
  return { arrived, release };
}

function pauseTokenWrite(env) {
  return pauseOnce(env.hooks, "beforeRun", (sql) => sql.startsWith("UPDATE web_shares SET public_token"));
}

test("authenticated status survives a fresh Worker process and database connection with the exact URL", async (t) => {
  const env = fixture(t);
  const created = await publish(env);
  const program = `import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import worker from ${JSON.stringify(new URL("../worker.mjs", import.meta.url).href)};
const python = ${JSON.stringify(python)};
${database.toString()}
const env = { DB: database(process.argv[1]), AUDIO: { get() {}, put() {}, head() {} }, SYNC_TOKEN: ${JSON.stringify(TOKEN)} };
const response = await worker.fetch(new Request(${JSON.stringify(BASE + PATH)}, { headers: { Authorization: ${JSON.stringify(`Bearer ${TOKEN}`)} } }), env);
assert.equal(response.status, 200);
process.stdout.write(await response.text());`;
  const restarted = spawnSync(process.execPath, ["--input-type=module", "-e", program, env.path], { encoding: "utf8" });
  assert.equal(restarted.status, 0, restarted.stderr);
  assert.deepEqual(JSON.parse(restarted.stdout), { active: true, ...created });
  assert.deepEqual(await status({ ...env, DB: database(env.path) }), { active: true, ...created });
  assert.equal(row(env).public_token, new URL(created.url).pathname.slice(3));
});

test("status requires authentication before disclosing or allocating a legacy token", async (t) => {
  const env = fixture(t);
  await legacy(env);
  const response = await request(env, PATH, { auth: false });
  assert.equal(response.status, 401);
  assert.equal(row(env).public_token, null);
  const active = await status(env);
  assert.deepEqual(Object.keys(active).sort(), ["active", "expiresAt", "url"]);
  assert.equal((await request(env, active.url, { auth: false })).status, 200);
});

test("legacy alias stays stable while the original URL, expiry, and snapshot remain unchanged", async (t) => {
  const env = fixture(t);
  const original = await legacy(env);
  const before = row(env);
  const active = await status(env);
  assert.notEqual(active.url, original.url);
  assert.equal(active.expiresAt, original.expiresAt);
  assert.equal((await request(env, original.url, { auth: false })).status, 200);
  assert.equal((await request(env, active.url, { auth: false })).status, 200);
  assert.deepEqual(await status({ ...env, DB: database(env.path) }), active);
  assert.deepEqual({ ...row(env), public_token: null }, before);
  assert.equal(env.objects.size, 1);
});

test("a successful original public read recovers the exact legacy URL before status allocates an alias", async (t) => {
  const env = fixture(t);
  const original = await legacy(env);
  assert.equal((await request(env, original.url, { auth: false })).status, 200);
  assert.deepEqual(await status(env), { active: true, ...original });
  assert.deepEqual(await status(env), { active: true, ...original });
});

test("a failed public snapshot read does not recover a legacy token", async (t) => {
  const env = fixture(t);
  const original = await legacy(env);
  env.objects.clear();
  assert.equal((await request(env, original.url, { auth: false })).status, 404);
  assert.equal(row(env).public_token, null);
});

test("concurrent legacy status reads return the same persisted winner", { timeout: 10_000 }, async (t) => {
  const env = fixture(t);
  await legacy(env);
  const gate = pauseTokenWrite(env);
  const first = status(env);
  await gate.arrived;
  const second = await status({ ...env, DB: database(env.path) });
  gate.release();
  assert.deepEqual(await first, second);
  assert.deepEqual(await status(env), second);
});

test("an original public read cannot overwrite a concurrently allocated stable alias", { timeout: 10_000 }, async (t) => {
  const env = fixture(t);
  const original = await legacy(env);
  const gate = pauseOnce(env.hooks, "beforeObjectGet");
  const page = request(env, original.url, { auth: false });
  await gate.arrived;
  const aliased = await status(env);
  gate.release();
  assert.equal((await page).status, 200);
  assert.deepEqual(await status(env), aliased);
});

for (const mutation of ["replace", "revoke", "expire"]) {
  test(`legacy status racing ${mutation} re-reads current state without resurrecting or modifying the share`, { timeout: 10_000 }, async (t) => {
    const env = fixture(t);
    const original = await legacy(env);
    const gate = pauseTokenWrite(env);
    const pending = status(env);
    await gate.arrived;
    let expected = { active: false };
    if (mutation === "replace") expected = { active: true, ...await publish(env, "Replacement") };
    if (mutation === "revoke") assert.equal((await request(env, PATH, { method: "DELETE" })).status, 204);
    if (mutation === "expire") env.DB.execute("UPDATE web_shares SET expires_at = ? WHERE source_id = ?", [Date.now() - 1, SOURCE]);
    const current = row(env);
    gate.release();
    assert.deepEqual(await pending, expected);
    assert.deepEqual(row(env), current);
    assert.equal((await request(env, original.url, { auth: false })).status, 404);
  });

  test(`both legacy URLs stop after ${mutation}, including a public read waiting on storage`, { timeout: 10_000 }, async (t) => {
    const env = fixture(t);
    const original = await legacy(env);
    const alias = await status(env);
    const gate = pauseOnce(env.hooks, "beforeObjectGet");
    const pending = request(env, alias.url, { auth: false });
    await gate.arrived;
    if (mutation === "replace") await publish(env, "Replacement");
    if (mutation === "revoke") await request(env, PATH, { method: "DELETE" });
    if (mutation === "expire") env.DB.execute("UPDATE web_shares SET expires_at = ? WHERE source_id = ?", [Date.now() - 1, SOURCE]);
    gate.release();
    assert.equal((await pending).status, 404);
    assert.equal((await request(env, original.url, { auth: false })).status, 404);
    assert.equal((await request(env, alias.url, { auth: false })).status, 404);
    if (mutation !== "replace") assert.deepEqual(await status(env), { active: false });
  });
}

test("migration preserves legacy hashes, allows multiple missing tokens, and enforces alias uniqueness", async (t) => {
  const env = fixture(t);
  await legacy(env);
  env.DB.execute(`INSERT INTO web_shares (source_id, token_hash, object_key, title, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?)`, [OTHER, "other-hash", "other-key", "Other", 1, Date.now() + 60_000]);
  const before = row(env);
  const active = await status(env);
  const token = new URL(active.url).pathname.slice(3);
  assert.throws(() => env.DB.execute("UPDATE web_shares SET public_token = ? WHERE source_id = ?", [token, OTHER]), /UNIQUE constraint failed/);
  assert.equal(row(env).token_hash, before.token_hash);
  const plan = env.DB.execute("EXPLAIN QUERY PLAN SELECT source_id FROM web_shares WHERE token_hash = ? OR public_token = ?", [before.token_hash, token]);
  assert.ok(plan.some((item) => item.detail.includes("idx_web_shares_public_token")));
});

test("health fails with pre-persistence schema and succeeds only after migration 0007", async (t) => {
  const env = fixture(t, { persistence: false });
  assert.equal((await request(env, "/v1/health")).status, 500);
  env.DB.execute(readFileSync(migrationURL, "utf8"), [], true);
  assert.equal((await request(env, "/v1/health")).status, 200);
});
