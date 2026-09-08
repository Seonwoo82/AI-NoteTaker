const SCHEMA_VERSION = 1;
const PAGE_SIZE = 100;
const METADATA_LIMIT_BYTES = 64 * 1024;
const AUDIO_LIMIT_BYTES = 95 * 1024 * 1024;
const NOTES_LIMIT_BYTES = 2 * 1024 * 1024;
const UUID_PATTERN = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;
const REVISION_PATTERN = /^[0-9a-f]{64}$/;
const NOTE_CURSOR_PATTERN = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}:\d{10}$/;
const MODES = new Set(["micAndSystem", "micOnly", "systemOnly"]);
const RECORDING_FIELDS = new Set([
  "schemaVersion",
  "id",
  "title",
  "createdAt",
  "duration",
  "isFavorite",
  "deletedAt",
  "mode",
  "audioVersion",
  "hasTranscript",
  "transcriptionError",
  "playbackRate",
  "skipsSilence",
  "enhances",
  "warnings",
  "modifiedAt",
  "mutationID",
]);
const OPTIONAL_NULL_FIELDS = new Set(["deletedAt", "transcriptionError"]);
const NOTE_FIELDS = new Set([
  "schemaVersion",
  "recordingID",
  "audioVersion",
  "generatedAt",
  "modelID",
  "transcriptionModelID",
  "markdown",
  "transcript",
  "costUSD",
]);

export default {
  async fetch(request, env) {
    try {
      return await handleRequest(request, env);
    } catch (error) {
      if (error instanceof HttpError) {
        return jsonError(error.status, error.code, error.message, error.headers);
      }
      return jsonError(500, "internal_error", "The sync service could not complete the request.");
    }
  },
};

async function handleRequest(request, env) {
  await requireAuthorization(request, env);

  const url = new URL(request.url);
  if (url.pathname === "/v1/health" && request.method === "GET") {
    return health(env);
  }

  if (url.pathname === "/v1/recordings" && request.method === "GET") {
    return listRecordings(env, url);
  }

  if (url.pathname === "/v1/notes" && request.method === "GET") {
    return listNotes(env, url);
  }

  if (url.pathname === "/v1/ai-settings" && request.method === "GET") {
    validateUUID(url.searchParams.get("deviceID"), "device ID");
    return getAISettings(env, url.searchParams.get("deviceID"));
  }
  if (url.pathname === "/v1/ai-settings" && request.method === "PUT") {
    return putAISettings(request, env);
  }

  const metadataMatch = url.pathname.match(/^\/v1\/recordings\/([^/]+)$/);
  if (metadataMatch && request.method === "PUT") {
    return putRecording(request, env, metadataMatch[1]);
  }

  const audioMatch = url.pathname.match(/^\/v1\/recordings\/([^/]+)\/audio\/([^/]+)$/);
  if (audioMatch && request.method === "PUT") {
    return putAudio(request, env, audioMatch[1], audioMatch[2]);
  }
  if (audioMatch && request.method === "GET") {
    return getAudio(env, audioMatch[1], audioMatch[2]);
  }

  const putNoteMatch = url.pathname.match(/^\/v1\/recordings\/([^/]+)\/notes\/([^/]+)$/);
  if (putNoteMatch && request.method === "PUT") {
    return putNote(request, env, putNoteMatch[1], putNoteMatch[2]);
  }

  const getNoteMatch = url.pathname.match(/^\/v1\/recordings\/([^/]+)\/notes\/([^/]+)\/([^/]+)$/);
  if (getNoteMatch && request.method === "GET") {
    return getNote(env, getNoteMatch[1], getNoteMatch[2], getNoteMatch[3]);
  }

  return jsonError(404, "not_found", "Endpoint was not found.");
}

const AI_SETTINGS_LIMIT_BYTES = 16 * 1024;
const AI_PREFERENCE_FIELDS = new Set([
  "schemaVersion", "modelID", "transcriptionModelID", "outputLanguage",
  "autoGenerate", "modifiedAt", "mutationID",
]);

function exactObject(value, fields, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).some((key) => !fields.has(key))) {
    throw new HttpError(400, "invalid_ai_settings", `${label} contains unsupported fields.`);
  }
}

function validateAIPreferences(value) {
  exactObject(value, AI_PREFERENCE_FIELDS, "AI preferences");
  const validModelID = (id) => typeof id === "string" && id.length <= 256 &&
    (id === "" || /^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$/.test(id));
  if (value.schemaVersion !== 1 || !validModelID(value.modelID) ||
      !validModelID(value.transcriptionModelID) || !["ko", "en", "source"].includes(value.outputLanguage) ||
      typeof value.autoGenerate !== "boolean" || !Number.isSafeInteger(value.modifiedAt) || value.modifiedAt < 0) {
    throw new HttpError(400, "invalid_ai_settings", "AI preference values are invalid.");
  }
  validateUUID(value.mutationID, "settings mutation ID");
  return value;
}

async function getAISettings(env, deviceID) {
  requireBindings(env);
  const row = await env.DB.prepare("SELECT preferences_json FROM ai_settings WHERE id = 1").first();
  const other = await env.DB.prepare(
    "SELECT device_id FROM ai_devices WHERE device_id <> ? AND has_api_key = 1 LIMIT 1",
  ).bind(deviceID).first();
  return json({ preferences: row ? JSON.parse(row.preferences_json) : null, otherDevicesHaveAPIKey: other !== null });
}

async function putAISettings(request, env) {
  requireBindings(env);
  assertBodySize(request, AI_SETTINGS_LIMIT_BYTES, "AI settings must not exceed 16 KiB.");
  const text = await readLimitedText(request, AI_SETTINGS_LIMIT_BYTES, "AI settings must not exceed 16 KiB.");
  let candidate;
  try { candidate = JSON.parse(text); }
  catch { throw new HttpError(400, "invalid_json", "AI settings must be valid JSON."); }
  exactObject(candidate, new Set(["preferences", "device"]), "AI settings");
  exactObject(candidate.device, new Set(["id", "platform", "hasAPIKey"]), "Device");
  const device = candidate.device;
  validateUUID(device.id, "device ID");
  if (!["macOS", "iOS"].includes(device.platform) ||
      (device.hasAPIKey != null && typeof device.hasAPIKey !== "boolean")) {
    throw new HttpError(400, "invalid_ai_settings", "Device information is invalid.");
  }
  const preferences = candidate.preferences == null ? null : validateAIPreferences(candidate.preferences);
  if (preferences) {
    await env.DB.prepare(
      `INSERT INTO ai_settings (id, preferences_json, modified_at, mutation_id) VALUES (1, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET preferences_json = excluded.preferences_json,
         modified_at = excluded.modified_at, mutation_id = excluded.mutation_id
       WHERE excluded.modified_at > ai_settings.modified_at
          OR (excluded.modified_at = ai_settings.modified_at AND excluded.mutation_id > ai_settings.mutation_id)`,
    ).bind(JSON.stringify(preferences), preferences.modifiedAt, preferences.mutationID).run();
  }
  await env.DB.prepare(
    `INSERT INTO ai_devices (device_id, platform, has_api_key) VALUES (?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET platform = excluded.platform,
       has_api_key = COALESCE(excluded.has_api_key, ai_devices.has_api_key)`,
  ).bind(device.id, device.platform, device.hasAPIKey == null ? null : Number(device.hasAPIKey)).run();
  return getAISettings(env, device.id);
}

async function health(env) {
  requireBindings(env);
  await env.DB.prepare("SELECT id FROM recordings ORDER BY id ASC LIMIT 1").first();
  await env.DB.prepare("SELECT recording_id FROM meeting_notes ORDER BY sync_key ASC LIMIT 1").first();
  await env.AUDIO.head(".healthcheck");
  return json({ ok: true, schemaVersion: SCHEMA_VERSION });
}

async function listRecordings(env, url) {
  requireBindings(env);
  const cursor = url.searchParams.get("cursor");
  if (cursor !== null && !UUID_PATTERN.test(cursor)) {
    throw new HttpError(400, "invalid_cursor", "cursor must be a canonical uppercase UUID.");
  }

  const result = await env.DB.prepare(
    `SELECT id, metadata_json, modified_at, mutation_id, audio_version, deleted_at
       FROM recordings
      WHERE (? IS NULL OR id > ?)
      ORDER BY id ASC
      LIMIT ?`,
  )
    .bind(cursor, cursor, PAGE_SIZE + 1)
    .all();
  const rows = result.results ?? [];
  const page = rows.slice(0, PAGE_SIZE);
  const recordings = page.map((row) => JSON.parse(row.metadata_json));
  const nextCursor = rows.length > PAGE_SIZE ? page[page.length - 1].id : null;
  return json({ recordings, nextCursor });
}

async function listNotes(env, url) {
  requireBindings(env);
  const cursor = url.searchParams.get("cursor");
  if (cursor !== null && !NOTE_CURSOR_PATTERN.test(cursor)) {
    throw new HttpError(400, "invalid_cursor", "cursor must be UPPERCASE-UUID:0000000001.");
  }

  const result = await env.DB.prepare(
    `SELECT recording_id, audio_version, generated_at_millis, revision, byte_count, sync_key
       FROM meeting_notes
      WHERE (? IS NULL OR sync_key > ?)
      ORDER BY sync_key ASC
      LIMIT ?`,
  )
    .bind(cursor, cursor, PAGE_SIZE + 1)
    .all();
  const rows = result.results ?? [];
  const page = rows.slice(0, PAGE_SIZE);
  const notes = page.map(noteDescriptorFromRow);
  const nextCursor = rows.length > PAGE_SIZE ? page[page.length - 1].sync_key : null;
  return json({ notes, nextCursor });
}

async function putRecording(request, env, pathID) {
  requireBindings(env);
  validateUUID(pathID, "recording id");
  assertBodySize(request, METADATA_LIMIT_BYTES, "Metadata must not exceed 64 KiB.");

  const body = await readLimitedText(request, METADATA_LIMIT_BYTES, "Metadata must not exceed 64 KiB.");
  let candidate;
  try {
    candidate = JSON.parse(body);
  } catch {
    throw new HttpError(400, "invalid_json", "Recording metadata must be valid JSON.");
  }

  const recording = validateRecording(candidate, pathID);
  const isDeleted = recording.deletedAt !== null;
  if (!isDeleted) {
    const audio = await env.AUDIO.get(audioKey(pathID, recording.audioVersion));
    if (!audio) {
      throw new HttpError(409, "missing_audio", "Upload audio before publishing live metadata.");
    }
  }

  await env.DB.prepare(
    `INSERT INTO recordings (id, metadata_json, modified_at, mutation_id, audio_version, deleted_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       metadata_json = excluded.metadata_json,
       modified_at = excluded.modified_at,
       mutation_id = excluded.mutation_id,
       audio_version = excluded.audio_version,
       deleted_at = excluded.deleted_at
     WHERE excluded.modified_at > recordings.modified_at
        OR (excluded.modified_at = recordings.modified_at
            AND excluded.mutation_id > recordings.mutation_id)`,
  )
    .bind(
      pathID,
      JSON.stringify(recording),
      recording.modifiedAt,
      recording.mutationID,
      recording.audioVersion,
      recording.deletedAt,
    )
    .run();

  const winner = await env.DB.prepare(
    `SELECT id, metadata_json, modified_at, mutation_id, audio_version, deleted_at
       FROM recordings
      WHERE id = ?`,
  )
    .bind(pathID)
    .first();
  return json({ recording: JSON.parse(winner.metadata_json) });
}

async function putAudio(request, env, pathID, pathAudioVersion) {
  requireBindings(env);
  validateUUID(pathID, "recording id");
  const audioVersion = parseAudioVersion(pathAudioVersion);
  const contentLength = requiredBodySize(request, AUDIO_LIMIT_BYTES, "Audio must not exceed 95 MiB.");

  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().startsWith("audio/mp4")) {
    throw new HttpError(415, "unsupported_media_type", "Audio uploads must use Content-Type audio/mp4.");
  }
  if (!request.body) {
    throw new HttpError(400, "invalid_audio", "Audio upload body is required.");
  }
  if (contentLength === 0) {
    throw new HttpError(400, "invalid_audio", "Audio upload body is required.");
  }

  const key = audioKey(pathID, audioVersion);
  const result = await env.AUDIO.put(key, request.body, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: {
      contentType: "audio/mp4",
      cacheControl: "no-store",
    },
  });

  return json({ key, immutable: true }, { status: result ? 201 : 200 });
}

async function getAudio(env, pathID, pathAudioVersion) {
  requireBindings(env);
  validateUUID(pathID, "recording id");
  const audioVersion = parseAudioVersion(pathAudioVersion);
  const object = await env.AUDIO.get(audioKey(pathID, audioVersion));
  if (!object) {
    throw new HttpError(404, "not_found", "Audio object was not found.");
  }

  const headers = new Headers();
  if (typeof object.writeHttpMetadata === "function") {
    object.writeHttpMetadata(headers);
  }
  headers.set("Content-Type", headers.get("Content-Type") ?? object.httpMetadata?.contentType ?? "audio/mp4");
  headers.set("Cache-Control", "no-store");
  if (typeof object.size === "number") {
    headers.set("Content-Length", String(object.size));
  }
  return new Response(object.body, { status: 200, headers });
}

async function putNote(request, env, pathID, pathAudioVersion) {
  requireBindings(env);
  validateUUID(pathID, "recording id");
  const audioVersion = parseAudioVersion(pathAudioVersion);
  assertBodySize(request, NOTES_LIMIT_BYTES, "Meeting notes must not exceed 2 MiB.");

  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new HttpError(415, "unsupported_media_type", "Meeting notes uploads must use Content-Type application/json.");
  }

  const bytes = await readLimitedBytes(request, NOTES_LIMIT_BYTES, "Meeting notes must not exceed 2 MiB.");
  if (bytes.byteLength === 0) {
    throw new HttpError(400, "invalid_notes", "Meeting notes document body is required.");
  }
  let candidate;
  try {
    candidate = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new HttpError(400, "invalid_json", "Meeting notes document must be valid JSON.");
  }

  const note = validateMeetingNotesDocument(candidate, pathID, audioVersion);
  const recording = await env.DB.prepare(
    `SELECT id, audio_version
       FROM recordings
      WHERE id = ?`,
  )
    .bind(pathID)
    .first();
  if (!recording) {
    throw new HttpError(409, "missing_recording", "Recording metadata must exist before publishing meeting notes.");
  }
  if (recording.audio_version !== audioVersion) {
    throw new HttpError(409, "audio_version_mismatch", "Meeting notes audioVersion must match the current recording metadata.");
  }

  const revision = await sha256Hex(bytes);
  const generatedAtMillis = Date.parse(note.generatedAt);
  const key = noteKey(pathID, audioVersion, revision);
  const putResult = await env.AUDIO.put(key, bytes, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: {
      contentType: "application/json",
      cacheControl: "no-store",
    },
  });
  if (putResult === null && !(await env.AUDIO.head(key))) {
    throw new HttpError(409, "immutable_write_conflict", "Meeting notes object could not be stored immutably.");
  }

  const syncKey = noteSyncKey(pathID, audioVersion);
  await env.DB.prepare(
    `INSERT INTO meeting_notes (recording_id, audio_version, generated_at_millis, revision, byte_count, object_key, sync_key)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(recording_id, audio_version) DO UPDATE SET
       generated_at_millis = excluded.generated_at_millis,
       revision = excluded.revision,
       byte_count = excluded.byte_count,
       object_key = excluded.object_key,
       sync_key = excluded.sync_key
     WHERE excluded.generated_at_millis > meeting_notes.generated_at_millis
        OR (excluded.generated_at_millis = meeting_notes.generated_at_millis
            AND excluded.revision > meeting_notes.revision)`,
  )
    .bind(pathID, audioVersion, generatedAtMillis, revision, bytes.byteLength, key, syncKey)
    .run();

  const winner = await env.DB.prepare(
    `SELECT recording_id, audio_version, generated_at_millis, revision, byte_count, sync_key
       FROM meeting_notes
      WHERE recording_id = ? AND audio_version = ?`,
  )
    .bind(pathID, audioVersion)
    .first();
  return json({ note: noteDescriptorFromRow(winner) });
}

async function getNote(env, pathID, pathAudioVersion, pathRevision) {
  requireBindings(env);
  validateUUID(pathID, "recording id");
  const audioVersion = parseAudioVersion(pathAudioVersion);
  if (!REVISION_PATTERN.test(pathRevision)) {
    throw new HttpError(400, "invalid_revision", "revision must be a lowercase 64-character SHA-256 hex string.");
  }

  const row = await env.DB.prepare(
    `SELECT object_key, byte_count
       FROM meeting_notes
      WHERE recording_id = ? AND audio_version = ? AND revision = ?`,
  )
    .bind(pathID, audioVersion, pathRevision)
    .first();
  if (!row) {
    throw new HttpError(404, "not_found", "Meeting notes descriptor was not found.");
  }

  const object = await env.AUDIO.get(row.object_key);
  if (!object) {
    throw new HttpError(404, "not_found", "Meeting notes object was not found.");
  }
  const headers = new Headers();
  headers.set("Content-Type", "application/json");
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Length", String(row.byte_count));
  return new Response(object.body, { status: 200, headers });
}

async function requireAuthorization(request, env) {
  const expected = env?.SYNC_TOKEN;
  if (typeof expected !== "string" || expected.length === 0) {
    throw new HttpError(500, "misconfigured", "SYNC_TOKEN secret is not configured.");
  }
  const header = request.headers.get("Authorization") ?? "";
  const provided = header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  if (!(await timingSafeEqual(provided, expected))) {
    throw new HttpError(401, "unauthorized", "Missing or invalid sync token.", { "WWW-Authenticate": "Bearer" });
  }
}

async function timingSafeEqual(left, right) {
  const encoder = new TextEncoder();
  const [leftDigest, rightDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const a = new Uint8Array(leftDigest);
  const b = new Uint8Array(rightDigest);
  let mismatch = 0;
  for (let index = 0; index < a.length; index += 1) {
    mismatch |= a[index] ^ b[index];
  }
  return mismatch === 0;
}

function requireBindings(env) {
  if (!env?.DB || typeof env.DB.prepare !== "function") {
    throw new HttpError(500, "misconfigured", "DB D1 binding is unavailable.");
  }
  if (
    !env?.AUDIO ||
    typeof env.AUDIO.get !== "function" ||
    typeof env.AUDIO.put !== "function" ||
    typeof env.AUDIO.head !== "function"
  ) {
    throw new HttpError(500, "misconfigured", "AUDIO R2 binding is unavailable.");
  }
}

function validateRecording(value, pathID) {
  if (!isPlainObject(value)) {
    throw new HttpError(400, "invalid_recording", "Recording metadata must be a JSON object.");
  }
  const normalized = { ...value };
  for (const field of OPTIONAL_NULL_FIELDS) {
    if (!Object.hasOwn(normalized, field)) {
      normalized[field] = null;
    }
  }
  for (const field of RECORDING_FIELDS) {
    if (!Object.hasOwn(normalized, field)) {
      throw new HttpError(400, "invalid_recording", `Recording metadata is missing ${field}.`);
    }
  }
  for (const field of Object.keys(normalized)) {
    if (!RECORDING_FIELDS.has(field)) {
      throw new HttpError(400, "invalid_recording", `Recording metadata contains unknown field ${field}.`);
    }
  }

  validateInteger(normalized.schemaVersion, "schemaVersion", 1, SCHEMA_VERSION);
  validateUUID(normalized.id, "id");
  if (normalized.id !== pathID) {
    throw new HttpError(400, "invalid_recording", "Recording id must match the URL.");
  }
  validateString(normalized.title, "title", 0, 1024);
  validateISODate(normalized.createdAt, "createdAt", false);
  validateFiniteNumber(normalized.duration, "duration", 0);
  validateBoolean(normalized.isFavorite, "isFavorite");
  validateISODate(normalized.deletedAt, "deletedAt", true);
  if (!MODES.has(normalized.mode)) {
    throw new HttpError(400, "invalid_recording", "mode must be micAndSystem, micOnly, or systemOnly.");
  }
  validateInteger(normalized.audioVersion, "audioVersion", 1, 2_147_483_647);
  validateBoolean(normalized.hasTranscript, "hasTranscript");
  if (normalized.transcriptionError !== null) {
    validateString(normalized.transcriptionError, "transcriptionError", 0, 4096);
  }
  validateFiniteNumber(normalized.playbackRate, "playbackRate", Number.MIN_VALUE);
  validateBoolean(normalized.skipsSilence, "skipsSilence");
  validateBoolean(normalized.enhances, "enhances");
  if (!Array.isArray(normalized.warnings) || normalized.warnings.some((warning) => typeof warning !== "string")) {
    throw new HttpError(400, "invalid_recording", "warnings must be an array of strings.");
  }
  validateInteger(normalized.modifiedAt, "modifiedAt", 0, Number.MAX_SAFE_INTEGER);
  validateUUID(normalized.mutationID, "mutationID");

  return normalized;
}

function validateMeetingNotesDocument(value, pathID, audioVersion) {
  if (!isPlainObject(value)) {
    throw new HttpError(400, "invalid_notes", "Meeting notes document must be a JSON object.");
  }
  for (const field of NOTE_FIELDS) {
    if (!Object.hasOwn(value, field)) {
      if (field === "costUSD") {
        continue;
      }
      throw new HttpError(400, "invalid_notes", `Meeting notes document is missing ${field}.`);
    }
  }
  for (const field of Object.keys(value)) {
    if (!NOTE_FIELDS.has(field)) {
      throw new HttpError(400, "invalid_notes", `Meeting notes document contains unknown field ${field}.`);
    }
  }

  validateInteger(value.schemaVersion, "schemaVersion", 1, SCHEMA_VERSION, "invalid_notes");
  validateUUID(value.recordingID, "recordingID");
  if (value.recordingID !== pathID) {
    throw new HttpError(400, "invalid_notes", "recordingID must match the URL.");
  }
  validateInteger(value.audioVersion, "audioVersion", 1, 2_147_483_647, "invalid_notes");
  if (value.audioVersion !== audioVersion) {
    throw new HttpError(400, "invalid_notes", "audioVersion must match the URL.");
  }
  validateISODate(value.generatedAt, "generatedAt", false, "invalid_notes");
  validateString(value.modelID, "modelID", 1, 512, "invalid_notes");
  validateString(value.transcriptionModelID, "transcriptionModelID", 1, 512, "invalid_notes");
  validateString(value.markdown, "markdown", 0, NOTES_LIMIT_BYTES, "invalid_notes");
  validateString(value.transcript, "transcript", 0, NOTES_LIMIT_BYTES, "invalid_notes");
  if (Object.hasOwn(value, "costUSD") && value.costUSD !== null) {
    validateFiniteNumber(value.costUSD, "costUSD", 0, "invalid_notes");
  }
  return value;
}

function validateUUID(value, label) {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new HttpError(400, "invalid_uuid", `${label} must be a canonical uppercase UUID.`);
  }
}

function validateString(value, label, minLength, maxLength, code = "invalid_recording") {
  if (typeof value !== "string" || value.length < minLength || value.length > maxLength) {
    throw new HttpError(400, code, `${label} must be a string up to ${maxLength} characters.`);
  }
}

function validateBoolean(value, label) {
  if (typeof value !== "boolean") {
    throw new HttpError(400, "invalid_recording", `${label} must be a boolean.`);
  }
}

function validateFiniteNumber(value, label, minimum, code = "invalid_recording") {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum) {
    throw new HttpError(400, code, `${label} must be a finite number greater than or equal to ${minimum}.`);
  }
}

function validateInteger(value, label, minimum, maximum, code = "invalid_recording") {
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new HttpError(400, code, `${label} must be an integer between ${minimum} and ${maximum}.`);
  }
}

function validateISODate(value, label, nullable, code = "invalid_recording") {
  if (value === null && nullable) {
    return;
  }
  if (typeof value !== "string" || !ISO_DATE_PATTERN.test(value) || Number.isNaN(Date.parse(value))) {
    throw new HttpError(400, code, `${label} must be an ISO8601 date string.`);
  }
}

function parseAudioVersion(value) {
  const parsed = Number(value);
  validateInteger(parsed, "audioVersion", 1, 2_147_483_647);
  if (String(parsed) !== value) {
    throw new HttpError(400, "invalid_audio_version", "audioVersion path component must be a positive integer.");
  }
  return parsed;
}

function assertBodySize(request, limit, message) {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength === null) {
    return;
  }
  const parsed = Number(contentLength);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new HttpError(400, "invalid_content_length", "Content-Length must be a non-negative integer.");
  }
  if (parsed > limit) {
    throw new HttpError(413, "payload_too_large", message);
  }
}

function requiredBodySize(request, limit, message) {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength === null) {
    throw new HttpError(411, "length_required", "Audio uploads require Content-Length so the stream can be stored without buffering.");
  }
  const parsed = Number(contentLength);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new HttpError(400, "invalid_content_length", "Content-Length must be a non-negative integer.");
  }
  if (parsed > limit) {
    throw new HttpError(413, "payload_too_large", message);
  }
  return parsed;
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
        throw new HttpError(413, "payload_too_large", message);
      }
      text += decoder.decode(value, { stream: true });
    }
  } finally {
    reader.releaseLock();
  }
  return text + decoder.decode();
}

async function readLimitedBytes(request, limit, message) {
  if (!request.body) {
    return new Uint8Array();
  }
  const reader = request.body.getReader();
  let bytes = 0;
  const chunks = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      bytes += value.byteLength;
      if (bytes > limit) {
        await reader.cancel();
        throw new HttpError(413, "payload_too_large", message);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function noteDescriptorFromRow(row) {
  return {
    recordingID: row.recording_id,
    audioVersion: row.audio_version,
    generatedAtMillis: row.generated_at_millis,
    revision: row.revision,
    byteCount: row.byte_count,
  };
}

function noStoreHeaders(headers) {
  headers.set("Cache-Control", "no-store");
  return headers;
}

function json(value, init = {}) {
  const headers = noStoreHeaders(new Headers(init.headers));
  headers.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(value), { ...init, headers });
}

function jsonError(status, code, message, extraHeaders = {}) {
  return json({ error: { code, message } }, { status, headers: extraHeaders });
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

class HttpError extends Error {
  constructor(status, code, message, headers = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

function audioKey(id, audioVersion) {
  return `recordings/${id}/audio/${audioVersion}.m4a`;
}

function noteKey(id, audioVersion, revision) {
  return `recordings/${id}/notes/${audioVersion}/${revision}.json`;
}

function noteSyncKey(id, audioVersion) {
  return `${id}:${String(audioVersion).padStart(10, "0")}`;
}
