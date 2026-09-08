import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";

import worker from "../worker.mjs";

const TOKEN = "synthetic-intelligence-token";
const BASE = "https://sync.example.com";
const RECORDING_ID = "11111111-2222-3333-8444-555555555555";
const OTHER_RECORDING_ID = "AAAAAAAA-BBBB-CCCC-8DDD-EEEEEEEEEEEE";
const MAC_DEVICE_ID = "99999999-AAAA-BBBB-8CCC-DDDDDDDDDDDD";
const PHONE_DEVICE_ID = "BBBBBBBB-AAAA-BBBB-8CCC-DDDDDDDDDDDD";

const python = `import json,sqlite3,sys
x=json.load(sys.stdin)
c=sqlite3.connect(x['path']);c.row_factory=sqlite3.Row
if x.get('script'): c.executescript(x['sql']); rows=[]
else: rows=[dict(r) for r in c.execute(x['sql'],x.get('values',[]))]
c.commit(); print(json.dumps(rows))`;

function database(path) {
  const execute = (sql, values = [], script = false) => {
    const result = spawnSync("python3", ["-c", python], {
      input: JSON.stringify({ path, sql, values, script }),
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  for (const name of readdirSync(new URL("../migrations/", import.meta.url)).sort()) {
    execute(readFileSync(new URL(`../migrations/${name}`, import.meta.url), "utf8"), [], true);
  }
  return {
    prepare(sql) {
      let values = [];
      return {
        bind(...next) { values = next; return this; },
        async first() { return execute(sql, values)[0] ?? null; },
        async all() { return { results: execute(sql, values) }; },
        async run() { execute(sql, values); return { success: true }; },
      };
    },
  };
}

function environment(t) {
  const folder = mkdtempSync(join(tmpdir(), "meeting-intelligence-sql-"));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  return { DB: database(join(folder, "test.sqlite")), AUDIO: new MemoryR2(), SYNC_TOKEN: TOKEN };
}

class MemoryR2 {
  constructor() {
    this.objects = new Map();
  }

  async put(key, value, options = {}) {
    if (options.onlyIf?.etagDoesNotMatch === "*" && this.objects.has(key)) {
      return null;
    }
    const body = await new Response(value).arrayBuffer();
    this.objects.set(key, { body, httpMetadata: options.httpMetadata ?? {} });
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

function authHeaders(extra = {}) {
  return { Authorization: `Bearer ${TOKEN}`, ...extra };
}

async function request(env, path, init = {}) {
  const headers = new Headers(init.headers ?? {});
  return worker.fetch(new Request(`${BASE}${path}`, { ...init, headers }), env);
}

async function readJson(response) {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    assert.fail(`expected JSON body, got ${text}`);
  }
}

function recording(id = RECORDING_ID, audioVersion = 1, overrides = {}) {
  return {
    schemaVersion: 1,
    id,
    title: "Morning note",
    createdAt: "2026-09-08T01:02:03.000Z",
    duration: 12.5,
    isFavorite: false,
    deletedAt: null,
    mode: "micOnly",
    audioVersion,
    hasTranscript: true,
    transcriptionError: null,
    playbackRate: 1,
    skipsSilence: false,
    enhances: false,
    warnings: [],
    modifiedAt: 1_788_310_923_000,
    mutationID: MAC_DEVICE_ID,
    ...overrides,
  };
}

async function uploadAudio(env, id = RECORDING_ID, audioVersion = 1) {
  const response = await request(env, `/v1/recordings/${id}/audio/${audioVersion}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "audio/mp4", "Content-Length": "5" }),
    body: "audio",
  });
  assert.equal(response.status, 201);
}

async function publishRecording(env, payload = recording()) {
  await uploadAudio(env, payload.id, payload.audioVersion);
  const response = await request(env, `/v1/recordings/${payload.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(payload),
  });
  assert.equal(response.status, 200);
}

function profile(overrides = {}) {
  return {
    schemaVersion: 1,
    displayName: "Seonwoo",
    aliases: ["선우", "Sonu"],
    role: "Product lead",
    automaticallyAnalyze: false,
    terms: [
      {
        id: "22222222-2222-4222-8222-222222222222",
        term: "AI-NoteTaker",
        spokenAs: "에이아이 노트테이커",
        meaning: "Personal meeting notes app",
        category: "project",
      },
    ],
    modifiedAt: 2_000,
    mutationID: MAC_DEVICE_ID,
    ...overrides,
  };
}

function intelligence(overrides = {}) {
  return {
    schemaVersion: 1,
    recordingID: RECORDING_ID,
    audioVersion: 1,
    modifiedAt: 2_000,
    mutationID: MAC_DEVICE_ID,
    projectName: "AI-NoteTaker",
    transcript: {
      schemaVersion: 1,
      recordingID: RECORDING_ID,
      audioVersion: 1,
      transcriptionModelID: "openai/whisper-test",
      speakers: [
        { id: "speaker-1", name: "Seonwoo", isOwner: true, manuallyAssigned: true },
        { id: "speaker-2", name: "Jin", isOwner: false, manuallyAssigned: false },
      ],
      turns: [
        { id: "turn-1", start: 0.0, end: 1.5, speakerID: "speaker-1", text: "I will update the README." },
        { id: "turn-2", start: 1.6, end: 3.0, speakerID: "speaker-2", text: "Can you add iPhone sync?" },
      ],
    },
    insights: {
      schemaVersion: 1,
      actions: [
        {
          id: "action-1",
          kind: "commitment",
          text: "Update the README",
          actorSpeakerID: "speaker-1",
          targetSpeakerID: null,
          dueText: null,
          evidenceTurnIDs: ["turn-1"],
        },
        {
          id: "action-2",
          kind: "request",
          text: "Add iPhone sync",
          actorSpeakerID: "speaker-2",
          targetSpeakerID: "speaker-1",
          dueText: "next release",
          evidenceTurnIDs: ["turn-2"],
        },
      ],
      questions: [
        {
          id: "question-1",
          question: "Can you add iPhone sync?",
          questionTurnIDs: ["turn-2"],
          answer: null,
          answerTurnIDs: [],
          status: "unanswered",
        },
      ],
      decisions: [
        {
          id: "decision-1",
          topic: "iPhone support",
          status: "decided",
          steps: [
            { kind: "proposal", text: "Add iPhone sync", speakerID: "speaker-2", evidenceTurnIDs: ["turn-2"] },
            { kind: "decision", text: "Ship Cloudflare sync", speakerID: "speaker-1", evidenceTurnIDs: ["turn-1"] },
          ],
        },
      ],
    },
    actionStates: {
      "action-1": "open",
      "action-2": "done",
    },
    analysisModelID: "openrouter/test-model",
    ...overrides,
  };
}

function revision(body) {
  return createHash("sha256").update(body).digest("hex");
}

function edit(overrides = {}) {
  return {
    schemaVersion: 1,
    id: "33333333-3333-4333-8333-333333333333",
    recordingID: RECORDING_ID,
    audioVersion: 1,
    modifiedAt: 2_000,
    kind: "speakerName",
    targetID: "speaker-1",
    value: "Seonwoo",
    ...overrides,
  };
}

test("profile routes require the existing bearer token", async (t) => {
  const env = environment(t);
  assert.equal((await request(env, "/v1/profile")).status, 401);
  assert.equal((await request(env, "/v1/profile", { method: "PUT", body: JSON.stringify({ profile: profile() }) })).status, 401);
});

test("profile accepts only text profile fields and resolves conflicts in SQLite", async (t) => {
  const env = environment(t);
  const first = await request(env, "/v1/profile", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ profile: profile() }),
  });
  const stale = await request(env, "/v1/profile", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ profile: profile({ displayName: "Stale", modifiedAt: 1_000, mutationID: PHONE_DEVICE_ID }) }),
  });
  const tieWinner = profile({ displayName: "Tie winner", mutationID: PHONE_DEVICE_ID });
  const winner = await request(env, "/v1/profile", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ profile: tieWinner }),
  });

  assert.equal(first.status, 200);
  assert.equal(stale.status, 200);
  assert.equal(winner.status, 200);
  assert.deepEqual(await readJson(winner), { profile: tieWinner });
  assert.deepEqual(await readJson(await request(env, "/v1/profile", { headers: authHeaders() })), { profile: tieWinner });
});

test("profile defaults missing automatic analysis opt-in to false for older clients", async (t) => {
  const env = environment(t);
  const olderClientProfile = profile();
  delete olderClientProfile.automaticallyAnalyze;

  const response = await request(env, "/v1/profile", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ profile: olderClientProfile }),
  });

  assert.equal(response.status, 200);
  assert.equal((await readJson(response)).profile.automaticallyAnalyze, false);
});

test("profile rejects secrets, voice material, unsupported fields, and oversized payloads", async (t) => {
  const env = environment(t);
  for (const payload of [
    { profile: { ...profile(), apiKey: "secret" } },
    { profile: { ...profile(), voiceEmbedding: [0.1] } },
    { profile: { ...profile(), terms: [{ ...profile().terms[0], category: "secret" }] } },
    { profile: { ...profile(), automaticallyAnalyze: "yes" } },
    { profile: { ...profile(), aliases: ["x".repeat(257)] } },
    { profile: { ...profile(), mutationID: "not-a-uuid" } },
    { profile: null, deviceName: "MacBook" },
  ]) {
    const response = await request(env, "/v1/profile", {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(payload),
    });
    assert.equal(response.status, 400);
  }

  const tooLarge = await request(env, "/v1/profile", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json", "Content-Length": String(64 * 1024 + 1) }),
    body: "{}",
  });
  assert.equal(tooLarge.status, 413);
});

test("meeting intelligence requires authentication, matching recording metadata, and current audio version", async (t) => {
  const env = environment(t);
  const body = JSON.stringify(intelligence());

  assert.equal((await request(env, "/v1/intelligence")).status, 401);
  assert.equal((await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body,
  })).status, 409);

  await publishRecording(env, recording(RECORDING_ID, 2));
  const mismatch = await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body,
  });
  assert.equal(mismatch.status, 409);
  assert.equal((await readJson(mismatch)).error.code, "audio_version_mismatch");
});

test("meeting intelligence stores exact immutable bytes and fetches by sha256 revision", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  const body = JSON.stringify(intelligence());
  const sha = revision(body);

  const put = await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1`, {
    method: "PUT",
    headers: authHeaders({
      "Content-Type": "application/json",
      "Content-Length": String(new TextEncoder().encode(body).byteLength),
    }),
    body,
  });
  const fetched = await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1/${sha}`, { headers: authHeaders() });

  assert.equal(put.status, 200);
  assert.deepEqual(await readJson(put), {
    intelligence: {
      recordingID: RECORDING_ID,
      audioVersion: 1,
      generatedAtMillis: 2_000,
      revision: sha,
      byteCount: new TextEncoder().encode(body).byteLength,
    },
  });
  assert.equal(fetched.status, 200);
  assert.equal(fetched.headers.get("Content-Type"), "application/json");
  assert.equal(fetched.headers.get("Cache-Control"), "no-store");
  assert.equal(await fetched.text(), body);
});

test("meeting intelligence validates references, strict shapes, content type, revision, and size", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  const invalidDocuments = [
    intelligence({ apiKey: "secret" }),
    intelligence({ transcript: { ...intelligence().transcript, turns: [{ id: "turn-1", start: 2, end: 1, speakerID: "speaker-1", text: "bad" }] } }),
    intelligence({ transcript: { ...intelligence().transcript, turns: [{ id: "turn-1", start: 0, end: 1, speakerID: "missing", text: "bad" }] } }),
    intelligence({ insights: { ...intelligence().insights, actions: [{ ...intelligence().insights.actions[0], evidenceTurnIDs: ["missing"] }] } }),
    intelligence({ insights: { ...intelligence().insights, decisions: [{ ...intelligence().insights.decisions[0], status: "bad" }] } }),
    intelligence({ actionStates: { "missing-action": "open" } }),
  ];
  for (const document of invalidDocuments) {
    const response = await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(document),
    });
    assert.equal(response.status, 400);
  }

  const contentType = await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "text/plain" }),
    body: JSON.stringify(intelligence()),
  });
  const badRevision = await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1/not-sha`, { headers: authHeaders() });
  const tooLarge = await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json", "Content-Length": String(4 * 1024 * 1024 + 1) }),
    body: "{}",
  });

  assert.equal(contentType.status, 415);
  assert.equal(badRevision.status, 400);
  assert.equal(tooLarge.status, 413);
});

test("meeting intelligence lists descriptors with pagination and uses modifiedAt plus mutationID LWW in SQLite", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  await publishRecording(env, recording(OTHER_RECORDING_ID, 2));

  const first = JSON.stringify(intelligence({ projectName: "First" }));
  const stale = JSON.stringify(intelligence({ projectName: "Stale", modifiedAt: 1_000, mutationID: "FFFFFFFF-AAAA-BBBB-8CCC-DDDDDDDDDDDD" }));
  const tieWinner = JSON.stringify(intelligence({ projectName: "Tie winner", mutationID: PHONE_DEVICE_ID }));
  for (const body of [first, stale, tieWinner]) {
    assert.equal((await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body,
    })).status, 200);
  }

  const other = JSON.stringify(intelligence({
    recordingID: OTHER_RECORDING_ID,
    audioVersion: 2,
    modifiedAt: 3_000,
    mutationID: MAC_DEVICE_ID,
    transcript: {
      ...intelligence().transcript,
      recordingID: OTHER_RECORDING_ID,
      audioVersion: 2,
    },
  }));
  assert.equal((await request(env, `/v1/recordings/${OTHER_RECORDING_ID}/intelligence/2`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: other,
  })).status, 200);

  const listed = await readJson(await request(env, `/v1/intelligence?cursor=${RECORDING_ID}:0000000001`, { headers: authHeaders() }));
  assert.deepEqual(listed, {
    intelligence: [
      {
        recordingID: OTHER_RECORDING_ID,
        audioVersion: 2,
        generatedAtMillis: 3_000,
        revision: revision(other),
        byteCount: new TextEncoder().encode(other).byteLength,
      },
    ],
    nextCursor: null,
  });

  const current = await readJson(await request(env, `/v1/recordings/${RECORDING_ID}/intelligence/1/${revision(tieWinner)}`, { headers: authHeaders() }));
  assert.equal(current.projectName, "Tie winner");
});

test("existing recording, notes, and ai settings routes still work with the new migration present", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  const notes = {
    schemaVersion: 1,
    recordingID: RECORDING_ID,
    audioVersion: 1,
    generatedAt: "2026-09-08T03:04:05.000Z",
    modelID: "openai/gpt-test",
    transcriptionModelID: "openai/whisper-test",
    markdown: "# Minutes",
    transcript: "Complete transcript",
    costUSD: null,
  };
  const notesBody = JSON.stringify(notes);
  const notePut = await request(env, `/v1/recordings/${RECORDING_ID}/notes/1`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: notesBody,
  });
  const settingsPut = await request(env, "/v1/ai-settings", {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({
      preferences: {
        schemaVersion: 1,
        modelID: "openrouter/auto",
        transcriptionModelID: "openrouter/stt",
        outputLanguage: "ko",
        autoGenerate: true,
        modifiedAt: 1_000,
        mutationID: MAC_DEVICE_ID,
      },
      device: { id: MAC_DEVICE_ID, platform: "macOS", hasAPIKey: true },
    }),
  });

  assert.equal(notePut.status, 200);
  assert.equal(settingsPut.status, 200);
  assert.equal((await readJson(await request(env, "/v1/recordings", { headers: authHeaders() }))).recordings.length, 1);
  assert.equal((await readJson(await request(env, "/v1/notes", { headers: authHeaders() }))).notes.length, 1);
  assert.equal((await readJson(await request(env, `/v1/recordings/${RECORDING_ID}/notes/1/${revision(notesBody)}`, { headers: authHeaders() }))).markdown, "# Minutes");
});

test("meeting edits require authentication and matching recording metadata", async (t) => {
  const env = environment(t);
  assert.equal((await request(env, "/v1/meeting-edits")).status, 401);

  const missing = await request(env, `/v1/meeting-edits/${edit().id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(edit()),
  });
  assert.equal(missing.status, 409);
  assert.equal((await readJson(missing)).error.code, "missing_recording");

  await publishRecording(env, recording(RECORDING_ID, 2));
  const mismatch = await request(env, `/v1/meeting-edits/${edit().id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(edit()),
  });
  assert.equal(mismatch.status, 409);
  assert.equal((await readJson(mismatch)).error.code, "audio_version_mismatch");
});

test("meeting edits append immutable entries and paginate after a sequence cursor", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  const first = edit();
  const second = edit({
    id: "44444444-4444-4444-8444-444444444444",
    kind: "actionStatus",
    targetID: "action-1",
    value: "done",
    modifiedAt: 2_001,
  });

  const firstPut = await request(env, `/v1/meeting-edits/${first.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(first),
  });
  const duplicate = await request(env, `/v1/meeting-edits/${first.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(first),
  });
  const secondPut = await request(env, `/v1/meeting-edits/${second.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(second),
  });
  const listed = await readJson(await request(env, "/v1/meeting-edits?after=1", { headers: authHeaders() }));

  assert.equal(firstPut.status, 200);
  assert.deepEqual(await readJson(firstPut), { entry: { sequence: 1, edit: first } });
  assert.equal(duplicate.status, 200);
  assert.equal(secondPut.status, 200);
  assert.deepEqual(listed, { entries: [{ sequence: 2, edit: second }], nextCursor: null });
});

test("meeting edit duplicate retries are idempotent under concurrent PUTs", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  const body = edit();

  const [first, second] = await Promise.all([
    request(env, `/v1/meeting-edits/${body.id}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(body),
    }),
    request(env, `/v1/meeting-edits/${body.id}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(body),
    }),
  ]);
  const firstPayload = await readJson(first);
  const secondPayload = await readJson(second);

  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.deepEqual(firstPayload, secondPayload);
  assert.deepEqual(firstPayload, { entry: { sequence: 1, edit: body } });
});

test("meeting edit duplicate retry returns the existing row after an insert race", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  const body = edit();
  const payload = JSON.stringify(body);
  await env.DB.prepare(
    `INSERT INTO meeting_edits (id, recording_id, audio_version, payload_json)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(body.id, body.recordingID, body.audioVersion, payload)
    .run();

  let hideExistingOnce = true;
  const raceEnv = {
    ...env,
    DB: {
      prepare(sql) {
        if (sql === "SELECT sequence, payload_json FROM meeting_edits WHERE id = ?") {
          let values = [];
          return {
            bind(...next) { values = next; return this; },
            async first() {
              if (hideExistingOnce) {
                hideExistingOnce = false;
                return null;
              }
              return env.DB.prepare(sql).bind(...values).first();
            },
            async all() { return env.DB.prepare(sql).bind(...values).all(); },
            async run() { return env.DB.prepare(sql).bind(...values).run(); },
          };
        }
        return env.DB.prepare(sql);
      },
    },
  };

  const response = await request(raceEnv, `/v1/meeting-edits/${body.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: payload,
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await readJson(response), { entry: { sequence: 1, edit: body } });
});

test("meeting edits reject same id with different payload and invalid edit shapes", async (t) => {
  const env = environment(t);
  await publishRecording(env);
  const first = edit();
  assert.equal((await request(env, `/v1/meeting-edits/${first.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(first),
  })).status, 200);

  const conflict = await request(env, `/v1/meeting-edits/${first.id}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ ...first, value: "Changed" }),
  });
  assert.equal(conflict.status, 409);
  assert.equal((await readJson(conflict)).error.code, "edit_conflict");

  for (const invalid of [
    edit({ apiKey: "secret" }),
    edit({ id: "not-a-uuid" }),
    edit({ kind: "voiceProfile" }),
    edit({ kind: "speakerOwner", value: "yes" }),
    edit({ kind: "actionStatus", value: "unknown" }),
    edit({ kind: "turnSpeaker", value: "speaker 1" }),
    edit({ kind: "projectName", targetID: "speaker-1" }),
    edit({ targetID: "한글" }),
    edit({ value: "x".repeat(257) }),
  ]) {
    const response = await request(env, `/v1/meeting-edits/${randomUUID().toUpperCase()}`, {
      method: "PUT",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(invalid),
    });
    assert.equal(response.status, 400);
  }

  const badCursor = await request(env, "/v1/meeting-edits?after=-1", { headers: authHeaders() });
  const tooLarge = await request(env, `/v1/meeting-edits/${randomUUID().toUpperCase()}`, {
    method: "PUT",
    headers: authHeaders({ "Content-Type": "application/json", "Content-Length": String(16 * 1024 + 1) }),
    body: "{}",
  });
  assert.equal(badCursor.status, 400);
  assert.equal(tooLarge.status, 413);
});
