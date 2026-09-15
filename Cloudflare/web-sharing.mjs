const SHARE_BODY_LIMIT_BYTES = 1024 * 1024 + 8 * 1024;
const SHARE_MARKDOWN_LIMIT_BYTES = 1024 * 1024;
const SHARE_TITLE_LIMIT_CODE_POINTS = 300;
const SHARE_TTL_MILLISECONDS = 7 * 24 * 60 * 60 * 1000;
const SHARE_SOURCE_UUID_PATTERN = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const SHARE_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const SHARE_FIELDS = new Set(["title", "markdown"]);

export class WebShareHttpError extends Error {
  constructor(status, code, message, headers = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

export async function handleShareManagement(request, env, sourceID) {
  requireShareBindings(env);
  const normalizedSourceID = normalizeSourceID(sourceID);
  if (request.method === "PUT") {
    return putShare(request, env, normalizedSourceID);
  }
  if (request.method === "GET") {
    return getShareStatus(request, env, normalizedSourceID);
  }
  if (request.method === "DELETE") {
    return deleteShare(env, normalizedSourceID);
  }
  throw new WebShareHttpError(405, "method_not_allowed", "Share endpoint method is not allowed.");
}

export async function handlePublicShare(env, token) {
  requireShareBindings(env);
  if (!SHARE_TOKEN_PATTERN.test(token)) {
    return notFoundPage();
  }

  const tokenHash = await sha256Text(token);
  const now = Date.now();
  const row = await env.DB.prepare(
    `SELECT source_id, token_hash, public_token, object_key, title, expires_at
       FROM web_shares
      WHERE (token_hash = ? OR public_token = ?) AND expires_at > ?`,
  )
    .bind(tokenHash, token, now)
    .first();
  if (!row) {
    return notFoundPage();
  }

  const object = await env.AUDIO.get(row.object_key);
  if (!object) {
    return notFoundPage();
  }

  let snapshot;
  try {
    snapshot = JSON.parse(await new Response(object.body).text());
  } catch {
    return notFoundPage();
  }
  if (!isPlainObject(snapshot) || typeof snapshot.title !== "string" || typeof snapshot.markdown !== "string") {
    return notFoundPage();
  }

  if (row.public_token == null) {
    // Recover a legacy URL when its original token is presented. Never replace
    // an alias already returned to an authenticated client or a newer share.
    await persistShareToken(env, row.source_id, row.token_hash, token);
  }
  const current = await env.DB.prepare(
    `SELECT expires_at FROM web_shares
      WHERE source_id = ? AND object_key = ?
        AND (token_hash = ? OR public_token = ?) AND expires_at > ?`,
  )
    .bind(row.source_id, row.object_key, tokenHash, token, Date.now())
    .first();
  if (!current) {
    return notFoundPage();
  }
  return htmlResponse(renderSharePage(snapshot.title, snapshot.markdown, current.expires_at), 200);
}

async function putShare(request, env, sourceID) {
  assertShareBodySize(request);
  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new WebShareHttpError(415, "unsupported_media_type", "Share uploads must use Content-Type application/json.");
  }

  const text = await readLimitedText(request, SHARE_BODY_LIMIT_BYTES, "Share payload must not exceed 1 MiB plus 8 KiB.");
  let candidate;
  try {
    candidate = JSON.parse(text);
  } catch {
    throw new WebShareHttpError(400, "invalid_json", "Share payload must be valid JSON.");
  }
  const snapshot = validateShareSnapshot(candidate);
  const token = randomToken();
  const tokenHash = await sha256Text(token);
  const now = Date.now();
  const expiresAt = now + SHARE_TTL_MILLISECONDS;
  const objectKey = `web-shares/${sourceID}/${now}-${tokenHash}.json`;
  const bytes = new TextEncoder().encode(JSON.stringify({
    title: snapshot.title,
    markdown: snapshot.markdown,
    createdAt: now,
    expiresAt,
  }));

  const putResult = await env.AUDIO.put(objectKey, bytes, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: {
      contentType: "application/json",
      cacheControl: "no-store",
    },
  });
  if (putResult === null) {
    throw new WebShareHttpError(500, "snapshot_write_conflict", "Share snapshot could not be stored.");
  }

  await env.DB.prepare(
    `INSERT INTO web_shares (source_id, token_hash, public_token, object_key, title, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(source_id) DO UPDATE SET
       token_hash = excluded.token_hash,
       public_token = excluded.public_token,
       object_key = excluded.object_key,
       title = excluded.title,
       created_at = excluded.created_at,
       expires_at = excluded.expires_at`,
  )
    .bind(sourceID, tokenHash, token, objectKey, snapshot.title, now, expiresAt)
    .run();

  return shareJson({
    url: `${new URL(request.url).origin}/s/${token}`,
    expiresAt,
  });
}

async function getShareStatus(request, env, sourceID) {
  const read = () => env.DB.prepare(
    `SELECT token_hash, public_token, expires_at
       FROM web_shares
      WHERE source_id = ?`,
  )
    .bind(sourceID)
    .first();
  let row = await read();
  if (!row || row.expires_at <= Date.now()) {
    return shareJson({ active: false });
  }
  if (row.public_token == null) {
    await persistShareToken(env, sourceID, row.token_hash, randomToken());
    // Another GET, publication, or revocation may have won the conditional
    // update. Return the persisted current state, never the candidate token.
    row = await read();
  }
  if (!row || row.public_token == null || row.expires_at <= Date.now()) {
    return shareJson({ active: false });
  }
  return shareJson({ active: true, url: `${new URL(request.url).origin}/s/${row.public_token}`, expiresAt: row.expires_at });
}

async function persistShareToken(env, sourceID, tokenHash, token) {
  await env.DB.prepare(
    `UPDATE web_shares SET public_token = ?
      WHERE source_id = ? AND token_hash = ? AND public_token IS NULL AND expires_at > ?`,
  )
    .bind(token, sourceID, tokenHash, Date.now())
    .run();
}

async function deleteShare(env, sourceID) {
  await env.DB.prepare("DELETE FROM web_shares WHERE source_id = ?")
    .bind(sourceID)
    .run();
  return new Response(null, { status: 204, headers: secureShareHeaders() });
}

function validateShareSnapshot(value) {
  if (!isPlainObject(value)) {
    throw new WebShareHttpError(400, "invalid_share", "Share payload must be a JSON object.");
  }
  for (const field of Object.keys(value)) {
    if (!SHARE_FIELDS.has(field)) {
      throw new WebShareHttpError(400, "invalid_share", `Share payload contains unsupported field ${field}.`);
    }
  }
  for (const field of SHARE_FIELDS) {
    if (!Object.hasOwn(value, field)) {
      throw new WebShareHttpError(400, "invalid_share", `Share payload is missing ${field}.`);
    }
  }

  if (typeof value.title !== "string") {
    throw new WebShareHttpError(400, "invalid_share", "Share title must be a string.");
  }
  const title = value.title.trim();
  if (title.length === 0 || Array.from(title).length > SHARE_TITLE_LIMIT_CODE_POINTS) {
    throw new WebShareHttpError(400, "invalid_share", "Share title must be trimmed, non-empty, and at most 300 characters.");
  }
  if (typeof value.markdown !== "string" || value.markdown.length === 0) {
    throw new WebShareHttpError(400, "invalid_share", "Share markdown must be non-empty.");
  }
  if (utf8Length(value.markdown) > SHARE_MARKDOWN_LIMIT_BYTES) {
    throw new WebShareHttpError(413, "payload_too_large", "Share markdown must not exceed 1 MiB UTF-8.");
  }
  return { title, markdown: value.markdown };
}

function normalizeSourceID(value) {
  if (typeof value !== "string") {
    throw new WebShareHttpError(400, "invalid_uuid", "source ID must be a canonical UUID.");
  }
  const normalized = value.toUpperCase();
  if (!SHARE_SOURCE_UUID_PATTERN.test(normalized)) {
    throw new WebShareHttpError(400, "invalid_uuid", "source ID must be a canonical UUID.");
  }
  return normalized;
}

function renderSharePage(title, markdown, expiresAt) {
  const body = renderMarkdown(markdown);
  const expiry = new Date(expiresAt).toLocaleString("ko-KR", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
  return `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow,noarchive">
<title>${escapeHtml(title)}</title>
<style>
:root{color-scheme:light dark;--bg:#f7f8fb;--panel:#ffffff;--ink:#18202f;--muted:#5d687a;--line:#dbe1ea;--accent:#2563eb;--code:#111827}
@media (prefers-color-scheme:dark){:root{--bg:#10131a;--panel:#171b24;--ink:#edf2ff;--muted:#a9b4c6;--line:#303747;--accent:#8ab4ff;--code:#070a10}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;overflow-wrap:anywhere;word-break:break-word}
main{width:min(880px,100%);margin:0 auto;padding:48px 20px 72px}
article{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:clamp(24px,5vw,48px);box-shadow:0 18px 48px rgba(24,32,47,.08)}
h1{font-size:clamp(2rem,5vw,3.25rem);line-height:1.1;margin:0 0 8px}h2,h3{line-height:1.25;margin:1.6em 0 .4em}
.brand{color:var(--accent);font-weight:700;letter-spacing:.02em;margin:0 0 20px}.meta{color:var(--muted);margin:0 0 32px;word-break:keep-all}p,ul,ol,blockquote,pre,table{margin:0 0 1em}
ul,ol{padding-left:1.4em}blockquote{border-left:4px solid var(--accent);padding-left:1em;color:var(--muted)}
pre{overflow:auto;background:var(--code);color:#f8fafc;border-radius:8px;padding:16px}code{font-family:"SFMono-Regular",Consolas,monospace;font-size:.92em}
:not(pre)>code{background:rgba(127,127,127,.14);padding:.1em .3em;border-radius:4px}
table{width:100%;border-collapse:collapse;display:block;overflow:auto}th,td{border:1px solid var(--line);padding:8px 10px;text-align:left}
</style>
</head>
<body>
<main>
<article>
<p class="brand">AI-NoteTaker</p>
<h1>${escapeHtml(title)}</h1>
<p class="meta">공유된 회의록입니다. ${escapeHtml(expiry)} 한국 시간 만료</p>
${body}
</article>
</main>
</body>
</html>`;
}

function renderMarkdown(markdown) {
  const blocks = [];
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (line.trim() === "") {
      index += 1;
      continue;
    }

    if (line.startsWith("```")) {
      const code = [];
      index += 1;
      while (index < lines.length && !lines[index].startsWith("```")) {
        code.push(lines[index]);
        index += 1;
      }
      if (index < lines.length) {
        index += 1;
      }
      blocks.push(`<pre><code>${escapeHtml(code.join("\n"))}</code></pre>`);
      continue;
    }

    const heading = /^(#{1,3})\s+(.+)$/.exec(line);
    if (heading) {
      const level = heading[1].length + 1;
      blocks.push(`<h${level}>${renderInline(heading[2].trim())}</h${level}>`);
      index += 1;
      continue;
    }

    if (/^\s*[-*]\s+/.test(line)) {
      const items = [];
      while (index < lines.length && /^\s*[-*]\s+/.test(lines[index])) {
        items.push(lines[index].replace(/^\s*[-*]\s+/, ""));
        index += 1;
      }
      blocks.push(`<ul>${items.map((item) => `<li>${renderInline(item)}</li>`).join("")}</ul>`);
      continue;
    }

    if (/^\s*\d+\.\s+/.test(line)) {
      const items = [];
      while (index < lines.length && /^\s*\d+\.\s+/.test(lines[index])) {
        items.push(lines[index].replace(/^\s*\d+\.\s+/, ""));
        index += 1;
      }
      blocks.push(`<ol>${items.map((item) => `<li>${renderInline(item)}</li>`).join("")}</ol>`);
      continue;
    }

    if (/^\s*>\s?/.test(line)) {
      const quotes = [];
      while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
        quotes.push(lines[index].replace(/^\s*>\s?/, ""));
        index += 1;
      }
      blocks.push(`<blockquote>${quotes.map((quote) => `<p>${renderInline(quote)}</p>`).join("")}</blockquote>`);
      continue;
    }

    if (isTableStart(lines, index)) {
      const header = splitTableRow(lines[index]);
      const align = splitTableRow(lines[index + 1]);
      const rows = [];
      index += 2;
      while (index < lines.length && lines[index].includes("|") && lines[index].trim() !== "") {
        rows.push(splitTableRow(lines[index]));
        index += 1;
      }
      const width = Math.max(header.length, align.length);
      blocks.push(`<table><thead><tr>${header.slice(0, width).map((cell) => `<th>${renderInline(cell.trim())}</th>`).join("")}</tr></thead><tbody>${rows.map((row) => `<tr>${row.slice(0, width).map((cell) => `<td>${renderInline(cell.trim())}</td>`).join("")}</tr>`).join("")}</tbody></table>`);
      continue;
    }

    const paragraph = [line.trim()];
    index += 1;
    while (index < lines.length && lines[index].trim() !== "" && !startsBlock(lines, index)) {
      paragraph.push(lines[index].trim());
      index += 1;
    }
    blocks.push(`<p>${renderInline(paragraph.join(" "))}</p>`);
  }
  return blocks.join("\n");
}

function startsBlock(lines, index) {
  const line = lines[index];
  return line.startsWith("```") ||
    /^(#{1,3})\s+/.test(line) ||
    /^\s*[-*]\s+/.test(line) ||
    /^\s*\d+\.\s+/.test(line) ||
    /^\s*>\s?/.test(line) ||
    isTableStart(lines, index);
}

function isTableStart(lines, index) {
  return index + 1 < lines.length &&
    lines[index].includes("|") &&
    /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(lines[index + 1]);
}

function splitTableRow(line) {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return trimmed.split("|");
}

function renderInline(value) {
  let output = "";
  let index = 0;
  while (index < value.length) {
    if (value[index] === "`") {
      const end = value.indexOf("`", index + 1);
      if (end !== -1) {
        output += `<code>${escapeHtml(value.slice(index + 1, end))}</code>`;
        index = end + 1;
        continue;
      }
    }
    if (value.startsWith("**", index)) {
      const end = value.indexOf("**", index + 2);
      if (end !== -1) {
        output += `<strong>${renderInline(value.slice(index + 2, end))}</strong>`;
        index = end + 2;
        continue;
      }
    }
    if (value[index] === "*") {
      const end = value.indexOf("*", index + 1);
      if (end !== -1) {
        output += `<em>${renderInline(value.slice(index + 1, end))}</em>`;
        index = end + 1;
        continue;
      }
    }
    const nextCode = value.indexOf("`", index);
    const nextEmphasis = value.indexOf("*", index);
    const nextSpecial = [nextCode, nextEmphasis]
      .filter((position) => position !== -1)
      .sort((left, right) => left - right)[0] ?? value.length;
    output += escapeHtml(value.slice(index, nextSpecial));
    index = nextSpecial;
  }
  return output;
}

function notFoundPage() {
  return htmlResponse(`<!doctype html>
<html lang="ko">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow,noarchive"><title>공유를 찾을 수 없습니다</title></head>
<body><main style="font:16px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:680px;margin:12vh auto;padding:0 20px;word-break:keep-all"><h1>공유를 찾을 수 없습니다</h1><p>이 링크는 사용할 수 없거나 만료되었습니다.</p></main></body>
</html>`, 404);
}

function htmlResponse(body, status) {
  const headers = secureShareHeaders();
  headers.set("Content-Type", "text/html; charset=utf-8");
  return new Response(body, { status, headers });
}

function shareJson(value) {
  const headers = secureShareHeaders();
  headers.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(value), { status: 200, headers });
}

function secureShareHeaders() {
  const headers = new Headers();
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Robots-Tag", "noindex, nofollow, noarchive");
  return headers;
}

function assertShareBodySize(request) {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength === null) {
    return;
  }
  const parsed = Number(contentLength);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new WebShareHttpError(400, "invalid_content_length", "Content-Length must be a non-negative integer.");
  }
  if (parsed > SHARE_BODY_LIMIT_BYTES) {
    throw new WebShareHttpError(413, "payload_too_large", "Share payload must not exceed 1 MiB plus 8 KiB.");
  }
}

async function readLimitedText(request, limit, message) {
  if (!request.body) {
    return "";
  }
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let bytes = 0;
  let text = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      bytes += value.byteLength;
      if (bytes > limit) {
        await reader.cancel();
        throw new WebShareHttpError(413, "payload_too_large", message);
      }
      text += decoder.decode(value, { stream: true });
    }
  } finally {
    reader.releaseLock();
  }
  return text + decoder.decode();
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Text(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[character]);
}

function utf8Length(text) {
  return new TextEncoder().encode(text).byteLength;
}

function requireShareBindings(env) {
  if (!env?.DB || typeof env.DB.prepare !== "function") {
    throw new WebShareHttpError(500, "misconfigured", "DB D1 binding is unavailable.");
  }
  if (
    !env?.AUDIO ||
    typeof env.AUDIO.get !== "function" ||
    typeof env.AUDIO.put !== "function" ||
    typeof env.AUDIO.head !== "function"
  ) {
    throw new WebShareHttpError(500, "misconfigured", "AUDIO R2 binding is unavailable.");
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
