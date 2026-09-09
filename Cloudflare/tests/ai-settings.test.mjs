import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import worker from '../worker.mjs';

const MAC = '11111111-2222-3333-4444-555555555555';
const PHONE = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
const TOKEN = 'synthetic-settings-sync-token';
const python = `import json,sqlite3,sys
x=json.load(sys.stdin)
c=sqlite3.connect(x['path']);c.row_factory=sqlite3.Row
if x.get('script'): c.executescript(x['sql']); rows=[]
else: rows=[dict(r) for r in c.execute(x['sql'],x.get('values',[]))]
c.commit(); print(json.dumps(rows))`;
function database(path) {
  const execute = (sql, values = [], script = false) => {
    const r = spawnSync('python3', ['-c', python], { input: JSON.stringify({ path, sql, values, script }), encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    return JSON.parse(r.stdout);
  };
  for (const name of readdirSync(new URL('../migrations/', import.meta.url)).sort()) {
    execute(readFileSync(new URL(`../migrations/${name}`, import.meta.url), 'utf8'), [], true);
  }
  return { prepare(sql) {
    let values = [];
    return {
      bind(...next) { values = next; return this; },
      async first() { return execute(sql, values)[0] ?? null; },
      async all() { return { results: execute(sql, values) }; },
      async run() { execute(sql, values); return { success: true }; }
    };
  }};
}
function environment(t) {
  const folder = mkdtempSync(join(tmpdir(), 'ai-settings-sql-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  return { DB: database(join(folder, 'test.sqlite')), AUDIO: { async head() { return null; }, async get() { throw new Error('Settings must not read audio'); }, async put() { throw new Error('Settings must not write audio'); } }, SYNC_TOKEN: TOKEN };
}
function preferences(overrides = {}) {
  return { schemaVersion: 1, modelID: 'test/summary', enhancementModelID: 'test/enhancement', transcriptionModelID: 'test/stt', outputLanguage: 'ko', autoGenerate: true,
    transcriptCleanupEnabled: true, modifiedAt: 1000, mutationID: MAC, ...overrides };
}
async function request(env, { method = 'GET', id = PHONE, payload, auth = true } = {}) {
  const url = 'https://example.test/v1/ai-settings' + (method === 'GET' ? `?deviceID=${id}` : '');
  return worker.fetch(new Request(url, { method, headers: { 'Content-Type': 'application/json', ...(auth ? { Authorization: `Bearer ${TOKEN}` } : {}) },
    ...(payload === undefined ? {} : { body: JSON.stringify(payload) }) }), env);
}
function upload(prefs = preferences(), device = { id: MAC, platform: 'macOS', hasAPIKey: true }) {
  return { preferences: prefs, device };
}

test('AI preferences require the existing bearer authentication', async t => {
  const env = environment(t);
  assert.equal((await request(env, { auth: false })).status, 401);
  assert.equal((await request(env, { method: 'PUT', payload: upload(), auth: false })).status, 401);
});
test('an empty workspace has no shared preferences or other-device key notice', async t => {
  const response = await request(environment(t));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { preferences: null, otherDevicesHaveAPIKey: false });
});
test('shared AI settings and key presence reach the other device without transmitting a key', async t => {
  const env = environment(t);
  const response = await request(env, { method: 'PUT', payload: upload() });
  assert.equal(response.status, 200);
  const phone = await (await request(env)).json();
  assert.deepEqual(phone, { preferences: preferences(), otherDevicesHaveAPIKey: true });
  const mac = await (await request(env, { id: MAC })).json();
  assert.equal(mac.otherDevicesHaveAPIKey, false);
  assert.deepEqual(Object.keys(phone).sort(), ['otherDevicesHaveAPIKey', 'preferences']);
});
test('actual SQLite ordering rejects older settings and breaks timestamp ties by mutation ID', async t => {
  const env = environment(t);
  assert.equal((await request(env, { method: 'PUT', payload: upload() })).status, 200);
  const newer = preferences({ mutationID: PHONE, modelID: 'test/newer' });
  assert.equal((await request(env, { method: 'PUT', payload: upload(newer) })).status, 200);
  await request(env, { method: 'PUT', payload: upload(preferences({ modifiedAt: 999 })) });
  assert.deepEqual((await (await request(env)).json()).preferences, newer);
});
test('key-only and unknown-presence updates preserve preferences and the last known presence', async t => {
  const env = environment(t);
  await request(env, { method: 'PUT', payload: upload() });
  const unknown = upload(null, { id: MAC, platform: 'macOS', hasAPIKey: null });
  assert.equal((await request(env, { method: 'PUT', payload: unknown })).status, 200);
  assert.equal((await (await request(env)).json()).otherDevicesHaveAPIKey, true);
  await request(env, { method: 'PUT', payload: upload(null, { id: MAC, platform: 'macOS', hasAPIKey: false }) });
  assert.deepEqual(await (await request(env)).json(), { preferences: preferences(), otherDevicesHaveAPIKey: false });
});
test('old clients that omit enhancementModelID do not erase a newer enhancement choice', async t => {
  const env = environment(t);
  await request(env, { method: 'PUT', payload: upload() });
  const oldClient = upload({
    schemaVersion: 1,
    modelID: 'test/summary',
    transcriptionModelID: 'test/stt',
    outputLanguage: 'en',
    autoGenerate: false,
    modifiedAt: 1001,
    mutationID: PHONE,
  }, { id: PHONE, platform: 'iOS', hasAPIKey: true });

  const response = await request(env, { method: 'PUT', payload: oldClient });

  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).preferences, {
    ...oldClient.preferences,
    enhancementModelID: 'test/enhancement',
    transcriptCleanupEnabled: true,
  });
});
test('explicit empty enhancementModelID clears a previous custom enhancement choice', async t => {
  const env = environment(t);
  await request(env, { method: 'PUT', payload: upload() });
  const response = await request(env, { method: 'PUT', payload: upload(preferences({
    enhancementModelID: '',
    modifiedAt: 1001,
    mutationID: PHONE,
  }), { id: PHONE, platform: 'iOS', hasAPIKey: true }) });

  assert.equal(response.status, 200);
  assert.equal((await response.json()).preferences.enhancementModelID, '');
});
test('old clients that omit transcriptCleanupEnabled keep the previous cleanup preference or default on', async t => {
  const env = environment(t);
  await request(env, { method: 'PUT', payload: upload(preferences({ transcriptCleanupEnabled: false })) });
  const oldClient = upload({
    schemaVersion: 1,
    modelID: 'test/summary',
    enhancementModelID: 'test/enhancement',
    transcriptionModelID: 'test/stt',
    outputLanguage: 'en',
    autoGenerate: false,
    modifiedAt: 1001,
    mutationID: PHONE,
  }, { id: PHONE, platform: 'iOS', hasAPIKey: true });
  const preserved = await request(env, { method: 'PUT', payload: oldClient });

  assert.equal(preserved.status, 200);
  assert.equal((await preserved.json()).preferences.transcriptCleanupEnabled, false);

  const fresh = environment(t);
  const defaulted = await request(fresh, { method: 'PUT', payload: oldClient });
  assert.equal(defaulted.status, 200);
  assert.equal((await defaulted.json()).preferences.transcriptCleanupEnabled, true);
});
test('an unconfigured new phone cannot erase shared settings', async t => {
  const env = environment(t);
  await request(env, { method: 'PUT', payload: upload() });
  const response = await request(env, { method: 'PUT', payload: upload(null, { id: PHONE, platform: 'iOS', hasAPIKey: false }) });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { preferences: preferences(), otherDevicesHaveAPIKey: true });
});
test('secret fields and malformed settings are rejected before changing stored state', async t => {
  const env = environment(t);
  await request(env, { method: 'PUT', payload: upload() });
  for (const payload of [
    { ...upload(), apiKey: 'synthetic-secret-must-not-be-stored' },
    upload(preferences({ apiKey: 'synthetic-secret-must-not-be-stored' })),
    upload(preferences(), { id: MAC, platform: 'macOS', hasAPIKey: false, apiKey: 'synthetic-secret' }),
    upload(preferences({ outputLanguage: 'unsupported' })),
    upload(preferences({ autoGenerate: 'yes' })),
    upload(preferences({ modelID: 'bad model with spaces' })),
    upload(preferences({ enhancementModelID: 'bad model with spaces' })),
    upload(preferences({ modifiedAt: Number.MAX_SAFE_INTEGER + 1 })),
    upload(preferences({ schemaVersion: 2 })),
    upload(preferences(), { id: MAC, platform: 'unknown', hasAPIKey: true }),
  ]) {
    assert.equal((await request(env, { method: 'PUT', payload })).status, 400);
  }
  assert.deepEqual(await (await request(env)).json(), { preferences: preferences(), otherDevicesHaveAPIKey: true });
});
test('device identifiers and oversized settings requests are bounded', async t => {
  const env = environment(t);
  assert.equal((await request(env, { id: 'bad' })).status, 400);
  assert.equal((await request(env, { method: 'PUT', payload: { padding: 'x'.repeat(20000) } })).status, 413);
});
