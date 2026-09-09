import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, test } from "node:test";

import worker from "../worker.mjs";

const TOKEN = "test-sync-token";
const BASE = "https://sync.example.com";
const VALID_ID = "11111111-2222-3333-8444-555555555555";
const OTHER_ID = "AAAAAAAA-BBBB-CCCC-8DDD-EEEEEEEEEEEE";
const FOLDER_ID = "22222222-3333-4444-8555-666666666666";
const NOTE_TIME = "2026-09-08T03:04:05.000Z";

function recording(overrides = {}) {
  return {
    schemaVersion: 1,
    id: VALID_ID,
    title: "Morning note",
    createdAt: "2026-09-08T01:02:03.000Z",
    duration: 12.5,
    isFavorite: false,
    deletedAt: null,
    mode: "micOnly",
    audioVersion: 1,
    hasTranscript: false,
    transcriptionError: null,
    playbackRate: 1,
    skipsSilence: false,
    enhances: false,
    warnings: [],
    modifiedAt: 1_788_310_923_000,
    mutationID: "99999999-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    ...overrides,
  };
}

function folder(overrides = {}) {
  return {
    schemaVersion: 1,
    id: FOLDER_ID,
    name: "Clients",
    createdAt: "2026-09-08T01:02:03.000Z",
    modifiedAt: 1_788_310_923_000,
    mutationID: "88888888-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    deletedAt: null,
    ...overrides,
  };
}

function meetingNotes(overrides = {}) {
  return {
    schemaVersion: 1,
    recordingID: VALID_ID,
    audioVersion: 1,
    generatedAt: NOTE_TIME,
    modelID: "openai/gpt-test",
    transcriptionModelID: "openai/whisper-test",
    markdown: "# Minutes\n\n- Item",
    transcript: "Complete transcript",
    costUSD: 0.12,
    ...overrides,
  };
}

function noteRevision(body) {
  return createHash("sha256").update(body).digest("hex");
}

function cleanupSourceHash(kind, source) {
  if (kind === "plain") {
    return createHash("sha256").update(`plain-v1\n${source}`, "utf8").digest("hex");
  }
  const payload = source.turns.map((turn) => `${new TextEncoder().encode(turn.id).byteLength}:${turn.id}${new TextEncoder().encode(turn.text).byteLength}:${turn.text}`).join("");
  return createHash("sha256").update(`speakers-v1\n${payload}`, "utf8").digest("hex");
}

function transcriptCleanup(overrides = {}) {
  return {
    schemaVersion: 1,
    modelID: "openai/gpt-cleanup",
    sourceKind: "plain",
    sourceHash: cleanupSourceHash("plain", "Complete transcript"),
    passages: [{ id: "p0", text: "Clean complete transcript." }],
    ...overrides,
  };
}

async function publishRecording(env, payload = recording()) {
  await uploadAudio(env, payload.id, payload.audioVersion);
  const response = await request(env, `/v1/recordings/${payload.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(payload),
  });
  assert.equal(response.status, 200);
  return response;
}

function authHeaders(extra = {}) {
  return { Authorization: `Bearer ${TOKEN}`, ...extra };
}

async function readJson(response) {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    assert.fail(`expected JSON body, got ${text}`);
  }
}

async function request(env, path, init = {}) {
  const headers = new Headers(init.headers ?? {});
  const response = await worker.fetch(new Request(`${BASE}${path}`, { ...init, headers }), env);
  return response;
}

async function uploadAudio(env, id = VALID_ID, version = 1, body = "audio-data") {
  return request(env, `/v1/recordings/${id}/audio/${version}`, {
    method: "PUT",
    headers: authHeaders({
      "Content-Type": "audio/mp4",
      "Content-Length": String(new TextEncoder().encode(body).byteLength),
    }),
    body,
  });
}

function makeEnv() {
  const db = new MemoryD1();
  return {
    DB: db,
    AUDIO: new MemoryR2(),
    SYNC_TOKEN: TOKEN,
    __db: db,
  };
}

class MemoryD1 {
  constructor() {
    this.rows = new Map();
    this.folderRows = new Map();
    this.noteRows = new Map();
    this.hasSchema = true;
    this.statements = [];
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
    if (this.sql.includes("FROM recordings") && this.sql.includes("LIMIT 1")) {
      if (!this.db.hasSchema) {
        throw new Error("no such table: recordings");
      }
      return { ok: 1 };
    }
    if (this.sql.includes("FROM meeting_notes") && this.sql.includes("LIMIT 1")) {
      if (!this.db.hasSchema) {
        throw new Error("no such table: meeting_notes");
      }
      return { ok: 1 };
    }
    if (this.sql.includes("FROM recording_folders") && this.sql.includes("LIMIT 1")) {
      if (!this.db.hasSchema) {
        throw new Error("no such table: recording_folders");
      }
      return { ok: 1 };
    }
    if (
      this.sql.includes("FROM recordings") &&
      this.sql.includes("audio_version") &&
      !this.sql.includes("metadata_json") &&
      this.sql.includes("WHERE id = ?")
    ) {
      const row = this.db.rows.get(this.values[0]);
      return row ? { id: row.id, audio_version: row.audio_version } : null;
    }
    if (this.sql.includes("WHERE id = ?")) {
      if (this.sql.includes("FROM recording_folders")) {
        return this.db.folderRows.get(this.values[0]) ?? null;
      }
      return this.db.rows.get(this.values[0]) ?? null;
    }
    if (this.sql.includes("FROM meeting_notes") && this.sql.includes("object_key")) {
      const key = `${this.values[0]}:${this.values[1]}`;
      const row = this.db.noteRows.get(key);
      return row && row.revision === this.values[2] ? row : null;
    }
    if (this.sql.includes("FROM meeting_notes") && this.sql.includes("recording_id = ? AND audio_version = ?")) {
      return this.db.noteRows.get(`${this.values[0]}:${this.values[1]}`) ?? null;
    }
    throw new Error(`unexpected first SQL: ${this.sql}`);
  }

  async all() {
    if (this.sql.includes("FROM meeting_notes")) {
      const cursor = this.values[0];
      const limit = this.values[2];
      const rows = [...this.db.noteRows.values()]
        .filter((row) => !cursor || row.sync_key > cursor)
        .sort((a, b) => a.sync_key.localeCompare(b.sync_key))
        .slice(0, limit);
      return { results: rows };
    }
    if (!this.sql.includes("FROM recordings")) {
      if (this.sql.includes("FROM recording_folders")) {
        const cursor = this.values[0];
        const limit = this.values[2];
        const rows = [...this.db.folderRows.values()]
          .filter((row) => !cursor || row.id > cursor)
          .sort((a, b) => a.id.localeCompare(b.id))
          .slice(0, limit);
        return { results: rows };
      }
      throw new Error(`unexpected all SQL: ${this.sql}`);
    }
    const cursor = this.values[0];
    const limit = this.values[2];
    const rows = [...this.db.rows.values()]
      .filter((row) => !cursor || row.id > cursor)
      .sort((a, b) => a.id.localeCompare(b.id))
      .slice(0, limit);
    return { results: rows };
  }

  async run() {
    if (this.sql.includes("INSERT INTO meeting_notes")) {
      this.db.statements.push({ sql: this.sql, values: this.values });
      const [recording_id, audio_version, generated_at_millis, revision, byte_count, object_key, sync_key] = this.values;
      const key = `${recording_id}:${audio_version}`;
      const existing = this.db.noteRows.get(key);
      const incomingWins =
        !existing ||
        generated_at_millis > existing.generated_at_millis ||
        (generated_at_millis === existing.generated_at_millis && revision > existing.revision);
      if (incomingWins) {
        this.db.noteRows.set(key, {
          recording_id,
          audio_version,
          generated_at_millis,
          revision,
          byte_count,
          object_key,
          sync_key,
        });
      }
      return { success: true };
    }
    if (this.sql.includes("INSERT INTO recording_folders")) {
      this.db.statements.push({ sql: this.sql, values: this.values });
      const [id, metadata_json, modified_at, mutation_id, deleted_at] = this.values;
      const existing = this.db.folderRows.get(id);
      const incomingWins =
        !existing ||
        modified_at > existing.modified_at ||
        (modified_at === existing.modified_at && mutation_id > existing.mutation_id);
      if (incomingWins) {
        this.db.folderRows.set(id, {
          id,
          metadata_json,
          modified_at,
          mutation_id,
          deleted_at,
        });
      }
      return { success: true };
    }
    if (!this.sql.includes("INSERT INTO recordings")) {
      throw new Error(`unexpected run SQL: ${this.sql}`);
    }
    this.db.statements.push({ sql: this.sql, values: this.values });
    const [id, metadata_json, modified_at, mutation_id, audio_version, deleted_at] = this.values;
    const existing = this.db.rows.get(id);
    const incomingWins =
      !existing ||
      modified_at > existing.modified_at ||
      (modified_at === existing.modified_at && mutation_id > existing.mutation_id);
    if (incomingWins) {
      this.db.rows.set(id, {
        id,
        metadata_json,
        modified_at,
        mutation_id,
        audio_version,
        deleted_at,
      });
    }
    return { success: true };
  }
}

class MemoryR2 {
  constructor() {
    this.objects = new Map();
    this.headCalls = [];
  }

  async put(key, value, options = {}) {
    if (options.onlyIf?.etagDoesNotMatch === "*") {
      if (this.objects.has(key)) {
        return null;
      }
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
    this.headCalls.push(key);
    return this.objects.get(key) ?? null;
  }
}

describe("Cloudflare sync worker", () => {
  test("rejects requests without the bearer token", async () => {
    const env = makeEnv();
    const response = await request(env, "/v1/health");

    assert.equal(response.status, 401);
    assert.equal(response.headers.get("WWW-Authenticate"), "Bearer");
    assert.deepEqual(await readJson(response), {
      error: {
        code: "unauthorized",
        message: "Missing or invalid sync token.",
      },
    });
  });

  test("reports authenticated health after DB and audio bindings are available", async () => {
    const env = makeEnv();
    const response = await request(env, "/v1/health", { headers: authHeaders() });

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(env.AUDIO.headCalls, [".healthcheck"]);
    assert.deepEqual(await readJson(response), { ok: true, schemaVersion: 1 });
  });

  test("reports unhealthy when the D1 recordings table is missing", async () => {
    const env = makeEnv();
    env.__db.hasSchema = false;

    const response = await request(env, "/v1/health", { headers: authHeaders() });

    assert.equal(response.status, 500);
    assert.deepEqual(await readJson(response), {
      error: {
        code: "internal_error",
        message: "The sync service could not complete the request.",
      },
    });
  });

  test("rejects incomplete or malformed recording metadata before D1 writes", async () => {
    const env = makeEnv();
    await uploadAudio(env);

    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(recording({ modifiedAt: -1, mutationID: "not-a-uuid" })),
    });

    assert.equal(response.status, 400);
    assert.equal(env.__db.rows.size, 0);
    assert.match((await readJson(response)).error.message, /modifiedAt/);
  });

  test("normalizes realistic Swift payloads that omit nil optional fields", async () => {
    const env = makeEnv();
    await uploadAudio(env);
    const payload = recording();
    delete payload.deletedAt;
    delete payload.transcriptionError;

    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(payload),
    });

    assert.equal(response.status, 200);
    const body = await readJson(response);
    assert.equal(body.recording.deletedAt, null);
    assert.equal(body.recording.transcriptionError, null);
  });

  test("preserves existing folder assignment when older clients omit the field", async () => {
    const env = makeEnv();
    await uploadAudio(env);
    const assigned = recording({ folderAssignment: { id: FOLDER_ID } });
    const legacy = recording({
      title: "Legacy rename",
      modifiedAt: assigned.modifiedAt + 1,
      mutationID: "AAAAAAAA-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(assigned),
    });
    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(legacy),
    });

    assert.equal(response.status, 200);
    const body = await readJson(response);
    assert.equal(body.recording.title, "Legacy rename");
    assert.deepEqual(body.recording.folderAssignment, { id: FOLDER_ID });
  });

  test("explicit empty folder assignment clears recording membership", async () => {
    const env = makeEnv();
    await uploadAudio(env);
    const assigned = recording({ folderAssignment: { id: FOLDER_ID } });
    const cleared = recording({
      folderAssignment: { id: null },
      modifiedAt: assigned.modifiedAt + 1,
      mutationID: "AAAAAAAA-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(assigned),
    });
    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(cleared),
    });

    assert.equal(response.status, 200);
    assert.deepEqual((await readJson(response)).recording.folderAssignment, { id: null });
  });

  test("folders round trip with tombstones and LWW ordering", async () => {
    const env = makeEnv();
    const first = folder({ name: "Clients" });
    const deleted = folder({
      name: "Archived",
      modifiedAt: first.modifiedAt + 1,
      mutationID: "AAAAAAAA-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
      deletedAt: "2026-09-08T02:03:04.000Z",
    });
    const stale = folder({
      name: "Stale",
      modifiedAt: first.modifiedAt - 1,
      mutationID: "FFFFFFFF-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    for (const payload of [first, deleted, stale]) {
      const put = await request(env, `/v1/folders/${FOLDER_ID}`, {
        method: "PUT",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify(payload),
      });
      assert.equal(put.status, 200);
    }
    const listed = await request(env, "/v1/folders", { headers: authHeaders() });

    assert.equal(listed.status, 200);
    assert.deepEqual(await readJson(listed), { folders: [deleted], nextCursor: null });
  });

  test("folders round trip sortOrder and preserve it when older clients omit the field", async () => {
    const env = makeEnv();
    const ordered = folder({ sortOrder: 7 });
    const legacy = folder({
      name: "Renamed by old client",
      modifiedAt: ordered.modifiedAt + 1,
      mutationID: "AAAAAAAA-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    const first = await request(env, `/v1/folders/${FOLDER_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(ordered),
    });
    const second = await request(env, `/v1/folders/${FOLDER_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(legacy),
    });

    assert.equal(first.status, 200);
    assert.equal(second.status, 200);
    assert.equal((await readJson(second)).folder.sortOrder, 7);
    assert.equal(JSON.parse(env.__db.folderRows.get(FOLDER_ID).metadata_json).sortOrder, 7);
  });

  test("rejects malformed folder sortOrder before changing stored state", async () => {
    const env = makeEnv();
    const valid = await request(env, `/v1/folders/${FOLDER_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(folder({ sortOrder: 1 })),
    });
    const invalid = await request(env, `/v1/folders/${FOLDER_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(folder({
        name: "Invalid rank",
        sortOrder: Number.MAX_SAFE_INTEGER + 1,
        modifiedAt: 1_788_310_924_000,
        mutationID: "AAAAAAAA-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
      })),
    });

    assert.equal(valid.status, 200);
    assert.equal(invalid.status, 400);
    assert.equal(JSON.parse(env.__db.folderRows.get(FOLDER_ID).metadata_json).sortOrder, 1);
  });

  test("folder names use user-visible characters consistently with Apple clients", async () => {
    const env = makeEnv();
    const response = await request(env, `/v1/folders/${FOLDER_ID}`, {
      method: "PUT", headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(folder({ name: "😀".repeat(120) })),
    });
    assert.equal(response.status, 200);
  });

  test("rejects malformed folder metadata before changing stored state", async () => {
    const env = makeEnv();
    const invalid = await request(env, `/v1/folders/${FOLDER_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(folder({ name: "   " })),
    });
    const extraField = await request(env, `/v1/folders/${FOLDER_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(folder({ secret: "nope" })),
    });

    assert.equal(invalid.status, 400);
    assert.equal(extraField.status, 400);
    assert.equal(env.__db.folderRows.size, 0);
  });

  test("generated recording_folders upsert SQL atomically applies tuple ordering in SQLite", async () => {
    const env = makeEnv();
    const first = folder({
      name: "First",
      modifiedAt: 1_788_310_930_000,
      mutationID: "BBBBBBBB-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });
    const stale = folder({
      name: "Stale",
      modifiedAt: 1_788_310_920_000,
      mutationID: "FFFFFFFF-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });
    const tieWinner = folder({
      name: "Tie Winner",
      modifiedAt: 1_788_310_930_000,
      mutationID: "CCCCCCCC-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    for (const payload of [first, stale, tieWinner]) {
      const response = await request(env, `/v1/folders/${FOLDER_ID}`, {
        method: "PUT",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify(payload),
      });
      assert.equal(response.status, 200);
    }

    const upserts = env.__db.statements.filter(({ sql }) => sql.includes("ON CONFLICT(id) DO UPDATE") && sql.includes("recording_folders"));
    assert.equal(upserts.length, 3);
    const child = spawnSync(
      "python3",
      [
        "-c",
        `
import json
import sqlite3
import sys

payload = json.load(sys.stdin)
conn = sqlite3.connect(':memory:')
conn.executescript(payload['migration'])
for statement in payload['statements']:
    conn.execute(statement['sql'], statement['values'])
row = conn.execute('SELECT metadata_json, modified_at, mutation_id FROM recording_folders WHERE id = ?', (payload['id'],)).fetchone()
assert row is not None
folder = json.loads(row[0])
assert folder['name'] == 'Tie Winner', row
assert row[1] == 1788310930000, row
assert row[2] == 'CCCCCCCC-AAAA-BBBB-8CCC-DDDDDDDDDDDD', row
print('recording_folders upsert sql ok')
`,
      ],
      {
        encoding: "utf8",
        input: JSON.stringify({
          migration: readFileSync(new URL("../migrations/0005_recording_folders.sql", import.meta.url), "utf8"),
          statements: upserts,
          id: FOLDER_ID,
        }),
      },
    );

    assert.equal(child.status, 0, child.stderr || child.stdout);
    assert.match(child.stdout, /recording_folders upsert sql ok/);
  });

  test("rejects present optional fields with non-null invalid types", async () => {
    const env = makeEnv();
    await uploadAudio(env);

    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(recording({ deletedAt: 123, transcriptionError: false })),
    });

    assert.equal(response.status, 400);
    assert.match((await readJson(response)).error.message, /deletedAt/);
  });

  test("requires live audio before accepting non-deleted metadata", async () => {
    const env = makeEnv();
    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(recording()),
    });

    assert.equal(response.status, 409);
    assert.deepEqual(await readJson(response), {
      error: {
        code: "missing_audio",
        message: "Upload audio before publishing live metadata.",
      },
    });
  });

  test("accepts tombstone metadata without audio", async () => {
    const env = makeEnv();
    const deleted = recording({
      deletedAt: "2026-09-08T02:03:04.000Z",
      modifiedAt: 1_788_310_924_000,
    });

    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(deleted),
    });

    assert.equal(response.status, 200);
    assert.deepEqual((await readJson(response)).recording, deleted);
  });

  test("stores audio immutably and returns the first uploaded bytes on duplicate retry", async () => {
    const env = makeEnv();
    const first = await request(env, `/v1/recordings/${VALID_ID}/audio/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "audio/mp4", "Content-Length": "11" }),
      body: "first-audio",
    });
    const retry = await request(env, `/v1/recordings/${VALID_ID}/audio/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "audio/mp4", "Content-Length": "15" }),
      body: "different-audio",
    });
    const fetched = await request(env, `/v1/recordings/${VALID_ID}/audio/1`, {
      headers: authHeaders(),
    });

    assert.equal(first.status, 201);
    assert.equal(retry.status, 200);
    assert.equal(fetched.status, 200);
    assert.equal(fetched.headers.get("Content-Type"), "audio/mp4");
    assert.equal(fetched.headers.get("Cache-Control"), "no-store");
    assert.equal(await fetched.text(), "first-audio");
  });

  test("rejects audio without Content-Length to avoid buffering large uploads", async () => {
    const env = makeEnv();
    const response = await request(env, `/v1/recordings/${VALID_ID}/audio/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "audio/mp4" }),
      body: "audio-data",
    });

    assert.equal(response.status, 411);
    assert.match((await readJson(response)).error.message, /Content-Length/);
  });

  test("returns 404 for missing audio", async () => {
    const env = makeEnv();
    const response = await request(env, `/v1/recordings/${VALID_ID}/audio/1`, {
      headers: authHeaders(),
    });

    assert.equal(response.status, 404);
    assert.deepEqual(await readJson(response), {
      error: {
        code: "not_found",
        message: "Audio object was not found.",
      },
    });
  });

  test("uses the last-edit-wins tuple and returns the server winner for stale metadata", async () => {
    const env = makeEnv();
    await uploadAudio(env);

    const newer = recording({
      title: "Newer",
      modifiedAt: 1_788_310_930_000,
      mutationID: "BBBBBBBB-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });
    const stale = recording({
      title: "Stale",
      modifiedAt: 1_788_310_920_000,
      mutationID: "CCCCCCCC-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(newer),
    });
    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(stale),
    });

    assert.equal(response.status, 200);
    assert.equal((await readJson(response)).recording.title, "Newer");
  });

  test("uses mutationID as the tie breaker for equal modifiedAt values", async () => {
    const env = makeEnv();
    await uploadAudio(env);

    const lower = recording({
      title: "Lower",
      modifiedAt: 1_788_310_930_000,
      mutationID: "10000000-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });
    const higher = recording({
      title: "Higher",
      modifiedAt: 1_788_310_930_000,
      mutationID: "F0000000-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(lower),
    });
    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(higher),
    });

    assert.equal(response.status, 200);
    assert.equal((await readJson(response)).recording.title, "Higher");
  });

  test("generated D1 upsert SQL atomically applies tuple ordering in SQLite", async () => {
    const env = makeEnv();
    await uploadAudio(env);

    const first = recording({
      title: "First",
      modifiedAt: 1_788_310_930_000,
      mutationID: "BBBBBBBB-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });
    const stale = recording({
      title: "Stale",
      modifiedAt: 1_788_310_920_000,
      mutationID: "FFFFFFFF-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });
    const tieWinner = recording({
      title: "Tie Winner",
      modifiedAt: 1_788_310_930_000,
      mutationID: "CCCCCCCC-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
    });

    for (const payload of [first, stale, tieWinner]) {
      const response = await request(env, `/v1/recordings/${VALID_ID}`, {
        method: "PUT",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify(payload),
      });
      assert.equal(response.status, 200);
    }

    const upserts = env.__db.statements.filter(({ sql }) => sql.includes("ON CONFLICT(id) DO UPDATE"));
    assert.equal(upserts.length, 3);
    const child = spawnSync(
      "python3",
      [
        "-c",
        `
import json
import sqlite3
import sys

payload = json.load(sys.stdin)
conn = sqlite3.connect(':memory:')
conn.executescript(payload['migration'])
for statement in payload['statements']:
    conn.execute(statement['sql'], statement['values'])
row = conn.execute('SELECT metadata_json, modified_at, mutation_id FROM recordings WHERE id = ?', (payload['id'],)).fetchone()
assert row is not None
recording = json.loads(row[0])
assert recording['title'] == 'Tie Winner', row
assert row[1] == 1788310930000, row
assert row[2] == 'CCCCCCCC-AAAA-BBBB-8CCC-DDDDDDDDDDDD', row
print('worker-generated upsert sql ok')
`,
      ],
      {
        encoding: "utf8",
        input: JSON.stringify({
          migration: readFileSync(new URL("../migrations/0001_recordings.sql", import.meta.url), "utf8"),
          statements: upserts,
          id: VALID_ID,
        }),
      },
    );

    assert.equal(child.status, 0, child.stderr || child.stdout);
    assert.match(child.stdout, /worker-generated upsert sql ok/);
  });

  test("paginates recordings after an uppercase UUID cursor", async () => {
    const env = makeEnv();
    for (const id of [OTHER_ID, VALID_ID]) {
      await uploadAudio(env, id);
      await request(env, `/v1/recordings/${id}`, {
        method: "PUT",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify(recording({ id })),
      });
    }

    const response = await request(env, `/v1/recordings?cursor=${VALID_ID}`, {
      headers: authHeaders(),
    });

    assert.equal(response.status, 200);
    assert.deepEqual(await readJson(response), {
      recordings: [recording({ id: OTHER_ID })],
      nextCursor: null,
    });
  });

  test("rejects metadata over 64 KiB and audio over 95 MiB using content length", async () => {
    const env = makeEnv();
    const metadataResponse = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({
        "Content-Type": "application/json",
        "Content-Length": String(64 * 1024 + 1),
      }),
      body: "{}",
    });
    const audioResponse = await request(env, `/v1/recordings/${VALID_ID}/audio/1`, {
      method: "PUT",
      headers: authHeaders({
        "Content-Type": "audio/mp4",
        "Content-Length": String(95 * 1024 * 1024 + 1),
      }),
      body: "x",
    });

    assert.equal(metadataResponse.status, 413);
    assert.match((await readJson(metadataResponse)).error.message, /64 KiB/);
    assert.equal(audioResponse.status, 413);
    assert.match((await readJson(audioResponse)).error.message, /95 MiB/);
  });

  test("rejects chunked metadata as soon as the streamed body crosses 64 KiB", async () => {
    const env = makeEnv();
    let canceled = false;
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array(64 * 1024));
        controller.enqueue(new Uint8Array(1));
      },
      cancel() {
        canceled = true;
      },
    });

    const response = await request(env, `/v1/recordings/${VALID_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: stream,
      duplex: "half",
    });

    assert.equal(response.status, 413);
    assert.equal(canceled, true);
    assert.match((await readJson(response)).error.message, /64 KiB/);
  });

  test("stores completed meeting notes by immutable SHA-256 revision and returns exact JSON bytes", async () => {
    const env = makeEnv();
    await publishRecording(env);
    const body = JSON.stringify(meetingNotes());
    const revision = noteRevision(body);

    const put = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT",
      headers: authHeaders({
        "Content-Type": "application/json",
        "Content-Length": String(new TextEncoder().encode(body).byteLength),
      }),
      body,
    });
    const fetched = await request(env, `/v1/recordings/${VALID_ID}/notes/1/${revision}`, {
      headers: authHeaders(),
    });

    assert.equal(put.status, 200);
    assert.deepEqual(await readJson(put), {
      note: {
        recordingID: VALID_ID,
        audioVersion: 1,
        generatedAtMillis: Date.parse(NOTE_TIME),
        revision,
        byteCount: new TextEncoder().encode(body).byteLength,
      },
    });
    assert.equal(fetched.status, 200);
    assert.equal(fetched.headers.get("Content-Type"), "application/json");
    assert.equal(fetched.headers.get("Cache-Control"), "no-store");
    assert.equal(await fetched.text(), body);
  });

  test("numbered transcript and enhancement metadata round trip with notes", async () => {
    const env = makeEnv();
    await publishRecording(env);
    const body = JSON.stringify(meetingNotes({
      speakerTranscript: {
        schemaVersion: 1, recordingID: VALID_ID, audioVersion: 1, transcriptionModelID: "fixture/stt",
        speakers: [{ id: "p1", name: "Participant", isOwner: false, manuallyAssigned: false }],
        turns: [{ id: "t1", start: 0, end: 1, speakerID: "p1", text: "7월 출시는 목표입니다." }],
      },
      enhancement: { modelID: "fixture/enhance", instructions: "7월 출시는 확정 일정이 아니라 목표입니다." },
    }));
    const put = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT", headers: authHeaders({ "Content-Type": "application/json" }), body,
    });
    assert.equal(put.status, 200);
    const fetched = await request(env, `/v1/recordings/${VALID_ID}/notes/1/${noteRevision(body)}`, { headers: authHeaders() });
    assert.equal(await fetched.text(), body);
  });

  test("transcript cleanup metadata round trips with notes and older notes may omit it", async () => {
    const env = makeEnv();
    await publishRecording(env);
    const legacyBody = JSON.stringify(meetingNotes());
    const cleanupBody = JSON.stringify(meetingNotes({
      generatedAt: "2026-09-08T03:04:06.000Z",
      transcript: "First paragraph.\n\nSecond paragraph.",
      transcriptCleanup: {
        schemaVersion: 1,
        modelID: "openai/gpt-cleanup",
        sourceKind: "plain",
        sourceHash: cleanupSourceHash("plain", "First paragraph.\n\nSecond paragraph."),
        passages: [{ id: "p0", text: "First paragraph." }, { id: "p1", text: "Second paragraph." }],
      },
    }));

    const legacy = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT", headers: authHeaders({ "Content-Type": "application/json" }), body: legacyBody,
    });
    const cleanup = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT", headers: authHeaders({ "Content-Type": "application/json" }), body: cleanupBody,
    });

    assert.equal(legacy.status, 200);
    assert.equal(cleanup.status, 200);
    const fetched = await request(env, `/v1/recordings/${VALID_ID}/notes/1/${noteRevision(cleanupBody)}`, { headers: authHeaders() });
    assert.equal(await fetched.text(), cleanupBody);
  });

  test("enhanced notes reject credential fields and mismatched transcript identity", async () => {
    const env = makeEnv();
    await publishRecording(env);
    for (const extra of [
      { enhancement: { modelID: "fixture/enhance", instructions: "fix", apiKey: "secret" } },
      { speakerTranscript: { schemaVersion: 1, recordingID: OTHER_ID, audioVersion: 1,
        transcriptionModelID: "fixture/stt", speakers: [], turns: [] } },
      { enhancement: { modelID: "fixture/enhance", instructions: "한".repeat(3000) } },
    ]) {
      const response = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
        method: "PUT", headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify(meetingNotes(extra)),
      });
      assert.equal(response.status, 400);
    }
  });

  test("transcript cleanup rejects incorrect hash, ids, oversize text, empty output, and unknown fields", async () => {
    const env = makeEnv();
    await publishRecording(env);
    const speakerTranscript = {
      schemaVersion: 1, recordingID: VALID_ID, audioVersion: 1, transcriptionModelID: "fixture/stt",
      speakers: [{ id: "p1", name: "Participant", isOwner: false, manuallyAssigned: false }],
      turns: [
        { id: "t1", start: 0, end: 1, speakerID: "p1", text: "Alpha" },
        { id: "t2", start: 1, end: 2, speakerID: "p1", text: "Beta" },
      ],
    };
    const validSpeakersCleanup = transcriptCleanup({
      sourceKind: "speakers",
      sourceHash: cleanupSourceHash("speakers", speakerTranscript),
      passages: [{ id: "t1", text: "Alpha." }, { id: "t2", text: "Beta." }],
    });
    const cases = [
      transcriptCleanup({ sourceHash: "0".repeat(64) }),
      transcriptCleanup({ passages: [{ id: "p1", text: "Clean complete transcript." }] }),
      transcriptCleanup({ passages: [{ id: "p0", text: "x".repeat(32 * 1024 + 1) }] }),
      transcriptCleanup({ passages: [{ id: "p0", text: "   " }] }),
      { ...transcriptCleanup(), apiKey: "secret" },
      { ...validSpeakersCleanup, passages: [{ id: "t2", text: "Beta." }, { id: "t1", text: "Alpha." }] },
      { ...validSpeakersCleanup, passages: [{ id: "t1", text: "Alpha." }, { id: "t2", text: "Beta." }, { id: "t3", text: "extra" }] },
    ];

    for (const cleanup of cases) {
      const response = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
        method: "PUT", headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify(meetingNotes({ speakerTranscript, transcriptCleanup: cleanup })),
      });
      assert.equal(response.status, 400);
    }
  });

  test("lists meeting notes with canonical UUID audio-version cursors", async () => {
    const env = makeEnv();
    const firstRecording = recording({ id: VALID_ID, audioVersion: 1 });
    const secondRecording = recording({ id: OTHER_ID, audioVersion: 2 });
    await publishRecording(env, firstRecording);
    await uploadAudio(env, OTHER_ID, 2);
    await request(env, `/v1/recordings/${OTHER_ID}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(secondRecording),
    });
    const firstBody = JSON.stringify(meetingNotes({ recordingID: VALID_ID, audioVersion: 1 }));
    const secondBody = JSON.stringify(meetingNotes({ recordingID: OTHER_ID, audioVersion: 2 }));
    await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: firstBody,
    });
    await request(env, `/v1/recordings/${OTHER_ID}/notes/2`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: secondBody,
    });

    const response = await request(env, `/v1/notes?cursor=${VALID_ID}:0000000001`, {
      headers: authHeaders(),
    });

    assert.equal(response.status, 200);
    assert.deepEqual(await readJson(response), {
      notes: [
        {
          recordingID: OTHER_ID,
          audioVersion: 2,
          generatedAtMillis: Date.parse(NOTE_TIME),
          revision: noteRevision(secondBody),
          byteCount: new TextEncoder().encode(secondBody).byteLength,
        },
      ],
      nextCursor: null,
    });
  });

  test("rejects invalid notes cursor, revision, document shape, and payload size", async () => {
    const env = makeEnv();
    await publishRecording(env);
    const badCursor = await request(env, "/v1/notes?cursor=not-a-cursor", { headers: authHeaders() });
    const badRevision = await request(env, `/v1/recordings/${VALID_ID}/notes/1/ABC`, { headers: authHeaders() });
    const badShape = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(meetingNotes({ recordingID: OTHER_ID, apiKey: "secret" })),
    });
    const tooLarge = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT",
      headers: authHeaders({
        "Content-Type": "application/json",
        "Content-Length": String(2 * 1024 * 1024 + 1),
      }),
      body: "{}",
    });

    assert.equal(badCursor.status, 400);
    assert.equal(badRevision.status, 400);
    assert.equal(badShape.status, 400);
    assert.match((await readJson(badShape)).error.message, /unknown field|recordingID/);
    assert.equal(tooLarge.status, 413);
    assert.match((await readJson(tooLarge)).error.message, /2 MiB/);
  });

  test("requires existing matching recording metadata before meeting notes publish", async () => {
    const env = makeEnv();
    const missing = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(meetingNotes()),
    });
    await publishRecording(env, recording({ audioVersion: 2 }));
    const mismatch = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(meetingNotes()),
    });

    assert.equal(missing.status, 409);
    assert.equal((await readJson(missing)).error.code, "missing_recording");
    assert.equal(mismatch.status, 409);
    assert.equal((await readJson(mismatch)).error.code, "audio_version_mismatch");
  });

  test("meeting notes descriptor uses generatedAt and revision LWW ordering", async () => {
    const env = makeEnv();
    await publishRecording(env);
    const firstBody = JSON.stringify(meetingNotes({ markdown: "A", generatedAt: "2026-09-08T03:04:05.000Z" }));
    const staleBody = JSON.stringify(meetingNotes({ markdown: "B", generatedAt: "2026-09-08T03:04:04.000Z" }));
    const tieWinnerBody = JSON.stringify(meetingNotes({ markdown: "Z", generatedAt: "2026-09-08T03:04:05.000Z" }));

    for (const body of [firstBody, staleBody, tieWinnerBody]) {
      const response = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
        method: "PUT",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body,
      });
      assert.equal(response.status, 200);
    }

    const listed = await readJson(await request(env, "/v1/notes", { headers: authHeaders() }));
    const expectedWinner = [firstBody, staleBody, tieWinnerBody]
      .map((body) => ({ body, revision: noteRevision(body), generatedAtMillis: Date.parse(JSON.parse(body).generatedAt) }))
      .sort((left, right) =>
        left.generatedAtMillis === right.generatedAtMillis
          ? left.revision.localeCompare(right.revision)
          : left.generatedAtMillis - right.generatedAtMillis,
      )
      .at(-1);
    assert.equal(listed.notes[0].revision, expectedWinner.revision);
  });

  test("generated meeting_notes upsert SQL atomically applies tuple ordering in SQLite", async () => {
    const env = makeEnv();
    await publishRecording(env);
    for (const body of [
      JSON.stringify(meetingNotes({ markdown: "First", generatedAt: "2026-09-08T03:04:05.000Z" })),
      JSON.stringify(meetingNotes({ markdown: "Stale", generatedAt: "2026-09-08T03:04:04.000Z" })),
      JSON.stringify(meetingNotes({ markdown: "Tie candidate", generatedAt: "2026-09-08T03:04:05.000Z" })),
    ]) {
      const response = await request(env, `/v1/recordings/${VALID_ID}/notes/1`, {
        method: "PUT",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body,
      });
      assert.equal(response.status, 200);
    }

    const upserts = env.__db.statements.filter(({ sql }) => sql.includes("INSERT INTO meeting_notes"));
    assert.equal(upserts.length, 3);
    const child = spawnSync(
      "python3",
      [
        "-c",
        `
import sqlite3
import sys
import json

payload = json.load(sys.stdin)
conn = sqlite3.connect(':memory:')
conn.executescript(payload['recordings_migration'])
conn.executescript(payload['notes_migration'])
conn.execute(
    'INSERT INTO recordings (id, metadata_json, modified_at, mutation_id, audio_version, deleted_at) VALUES (?, ?, ?, ?, ?, ?)',
    (payload['id'], '{}', 1, payload['mutation_id'], 1, None),
)
for statement in payload['statements']:
    conn.execute(statement['sql'], statement['values'])
rows = conn.execute('SELECT revision, generated_at_millis FROM meeting_notes WHERE recording_id = ? AND audio_version = 1', (payload['id'],)).fetchall()
assert len(rows) == 1, rows
assert rows[0][0] == payload['winner_revision'], rows
assert rows[0][1] == payload['winner_millis'], rows
print('meeting_notes upsert sql ok')
`,
      ],
      {
        encoding: "utf8",
        input: JSON.stringify({
          recordings_migration: readFileSync(new URL("../migrations/0001_recordings.sql", import.meta.url), "utf8"),
          notes_migration: readFileSync(new URL("../migrations/0002_meeting_notes.sql", import.meta.url), "utf8"),
          statements: upserts,
          id: VALID_ID,
          mutation_id: "99999999-AAAA-BBBB-8CCC-DDDDDDDDDDDD",
          winner_revision: env.__db.noteRows.get(`${VALID_ID}:1`).revision,
          winner_millis: env.__db.noteRows.get(`${VALID_ID}:1`).generated_at_millis,
        }),
      },
    );

    assert.equal(child.status, 0, child.stderr || child.stdout);
    assert.match(child.stdout, /meeting_notes upsert sql ok/);
  });
});
