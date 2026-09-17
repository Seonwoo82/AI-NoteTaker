// Local-only integration harness: actual Worker handlers and SQLite SQL, filesystem stand-in for R2.
// Run: node Cloudflare/tests/local-sync-server.mjs <isolated-output-directory>
import { createServer } from 'node:http';
import { mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync, renameSync } from 'node:fs';
import { resolve, join, dirname, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import worker from '../worker.mjs';

const root = resolve(process.argv[2]); mkdirSync(root, { recursive: true });
const database = join(root, 'sync.sqlite');
const python = `import sqlite3,json,sys
x=json.load(sys.stdin); c=sqlite3.connect(x['database']); c.row_factory=sqlite3.Row
if x.get('script'): c.executescript(x['sql']); rows=[]
else: rows=[dict(r) for r in c.execute(x['sql'],x.get('values',[]))]
c.commit(); print(json.dumps(rows))`;
function execute(sql, values = [], script = false) {
  const result = spawnSync(process.env.PYTHON ?? 'python3', ['-X', 'utf8', '-c', python], { input: JSON.stringify({ database, sql, values, script }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr);
  return JSON.parse(result.stdout);
}
// Schema migrations run once; restart exercises persisted data without rebuilding it.
if (!existsSync(join(root, 'migrated'))) {
  for (const file of readdirSync(new URL('../migrations/', import.meta.url)).sort()) execute(readFileSync(new URL(`../migrations/${file}`, import.meta.url), 'utf8'), [], true);
  writeFileSync(join(root, 'migrated'), '8');
}
const DB = { prepare(sql) { let values = []; return {
  bind(...next) { values = next; return this; },
  async first() { return execute(sql, values)[0] ?? null; },
  async all() { return { results: execute(sql, values) }; },
  async run() { execute(sql, values); return { success: true }; }
}; } };
const objectRoot = join(root, 'objects'); mkdirSync(objectRoot, { recursive: true });
function pathFor(key) {
  const path = resolve(objectRoot, key);
  if (!path.startsWith(objectRoot + sep)) throw new Error('Object escaped test workspace'); return path;
}
const AUDIO = {
  async head(key) { const path = pathFor(key); return existsSync(path) ? { size: readFileSync(path).length } : null; },
  async get(key) {
    const path = pathFor(key); if (!existsSync(path)) return null;
    const bytes = readFileSync(path), metadata = JSON.parse(readFileSync(path + '.meta', 'utf8'));
    return { body: new Uint8Array(bytes), size: bytes.length, httpMetadata: metadata,
      writeHttpMetadata(headers) { if (metadata.contentType) headers.set('Content-Type', metadata.contentType); },
      async text() { return bytes.toString('utf8'); } };
  },
  async put(key, body, options = {}) {
    const path = pathFor(key); if (options.onlyIf?.etagDoesNotMatch === '*' && existsSync(path)) return null;
    const bytes = Buffer.from(await new Response(body).arrayBuffer()); mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path + '.part', bytes); writeFileSync(path + '.meta', JSON.stringify(options.httpMetadata ?? {})); renameSync(path + '.part', path);
    return { key, etag: createHash('sha256').update(bytes).digest('hex') };
  }
};
const server = createServer(async (incoming, outgoing) => {
  try {
    const chunks = []; let length = 0;
    for await (const chunk of incoming) { length += chunk.length; if (length > 100 * 1024 * 1024) throw new Error('Request too large'); chunks.push(chunk); }
    const bytes = Buffer.concat(chunks);
    const request = new Request('https://sync.fixture' + incoming.url, { method: incoming.method, headers: incoming.headers, ...(bytes.length ? { body: bytes } : {}) });
    const response = await worker.fetch(request, { DB, AUDIO, SYNC_TOKEN: 'synthetic-windows-sync-token' });
    outgoing.writeHead(response.status, Object.fromEntries(response.headers)); outgoing.end(Buffer.from(await response.arrayBuffer()));
  } catch (error) { outgoing.writeHead(500, { 'Content-Type': 'application/json' }); outgoing.end(JSON.stringify({ harnessError: String(error) })); }
});
server.listen(0, '127.0.0.1', () => process.stdout.write(JSON.stringify({ port: server.address().port }) + '\n'));
