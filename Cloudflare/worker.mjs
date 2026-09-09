const SCHEMA_VERSION = 1;
const PAGE_SIZE = 100;
const METADATA_LIMIT_BYTES = 64 * 1024;
const FOLDERS_LIMIT_BYTES = 64 * 1024;
const AUDIO_LIMIT_BYTES = 95 * 1024 * 1024;
const NOTES_LIMIT_BYTES = 2 * 1024 * 1024;
const INTELLIGENCE_LIMIT_BYTES = 4 * 1024 * 1024;
const MEETING_EDIT_LIMIT_BYTES = 16 * 1024;
const UUID_PATTERN = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;
const REVISION_PATTERN = /^[0-9a-f]{64}$/;
const NOTE_CURSOR_PATTERN = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}:\d{10}$/;
const CLEANUP_SOURCE_HASH_PATTERN = /^[0-9a-f]{64}$/;
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
  "folderAssignment",
  "modifiedAt",
  "mutationID",
]);
const OPTIONAL_NULL_FIELDS = new Set(["deletedAt", "transcriptionError"]);
const RECORDING_OPTIONAL_FIELDS = new Set(["folderAssignment"]);
const FOLDER_FIELDS = new Set([
  "schemaVersion",
  "id",
  "name",
  "createdAt",
  "modifiedAt",
  "mutationID",
  "deletedAt",
  "sortOrder",
]);
const FOLDER_NULL_FIELDS = new Set(["deletedAt"]);
const FOLDER_OPTIONAL_FIELDS = new Set(["sortOrder"]);
const FOLDER_ASSIGNMENT_FIELDS = new Set(["id"]);
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
  "speakerTranscript",
  "enhancement",
  "transcriptCleanup",
]);
const TRANSCRIPT_CLEANUP_FIELDS = new Set(["schemaVersion", "modelID", "sourceKind", "sourceHash", "passages"]);
const TRANSCRIPT_CLEANUP_PASSAGE_FIELDS = new Set(["id", "text"]);
const PROFILE_LIMIT_BYTES = 64 * 1024;
const PROFILE_BODY_FIELDS = new Set(["profile"]);
const PROFILE_FIELDS = new Set(["schemaVersion", "displayName", "aliases", "role", "terms", "automaticallyAnalyze", "modifiedAt", "mutationID"]);
const PROFILE_TERM_FIELDS = new Set(["id", "term", "spokenAs", "meaning", "category"]);
const PROFILE_TERM_CATEGORIES = new Set(["person", "organization", "project", "abbreviation", "general"]);
const INTELLIGENCE_FIELDS = new Set([
  "schemaVersion", "recordingID", "audioVersion", "modifiedAt", "mutationID", "projectName",
  "transcript", "insights", "actionStates", "analysisModelID",
]);
const TRANSCRIPT_FIELDS = new Set(["schemaVersion", "recordingID", "audioVersion", "transcriptionModelID", "speakers", "turns"]);
const SPEAKER_FIELDS = new Set(["id", "name", "isOwner", "manuallyAssigned"]);
const TURN_FIELDS = new Set(["id", "start", "end", "speakerID", "text"]);
const INSIGHTS_FIELDS = new Set(["schemaVersion", "actions", "questions", "decisions"]);
const ACTION_FIELDS = new Set(["id", "kind", "text", "actorSpeakerID", "targetSpeakerID", "dueText", "evidenceTurnIDs"]);
const QUESTION_FIELDS = new Set(["id", "question", "questionTurnIDs", "answer", "answerTurnIDs", "status"]);
const DECISION_FIELDS = new Set(["id", "topic", "status", "steps"]);
const DECISION_STEP_FIELDS = new Set(["kind", "text", "speakerID", "evidenceTurnIDs"]);
const ACTION_KINDS = new Set(["commitment", "request"]);
const QUESTION_STATUSES = new Set(["answered", "partial", "unanswered", "uncertain"]);
const DECISION_STATUSES = new Set(["decided", "deferred", "unresolved"]);
const DECISION_STEP_KINDS = new Set(["proposal", "concern", "decision", "deferred", "revised"]);
const ACTION_STATES = new Set(["open", "done", "dismissed"]);
const MEETING_EDIT_FIELDS = new Set(["schemaVersion", "id", "recordingID", "audioVersion", "modifiedAt", "kind", "targetID", "value"]);
const MEETING_EDIT_KINDS = new Set(["speakerName", "speakerOwner", "turnSpeaker", "actionStatus", "projectName"]);

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

  if (url.pathname === "/v1/folders" && request.method === "GET") {
    return listFolders(env, url);
  }

  if (url.pathname === "/v1/notes" && request.method === "GET") {
    return listNotes(env, url);
  }

  if (url.pathname === "/v1/intelligence" && request.method === "GET") {
    return listIntelligence(env, url);
  }

  if (url.pathname === "/v1/profile" && request.method === "GET") {
    return getProfile(env);
  }
  if (url.pathname === "/v1/profile" && request.method === "PUT") {
    return putProfile(request, env);
  }

  if (url.pathname === "/v1/meeting-edits" && request.method === "GET") {
    return listMeetingEdits(env, url);
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

  const folderMatch = url.pathname.match(/^\/v1\/folders\/([^/]+)$/);
  if (folderMatch && request.method === "PUT") {
    return putFolder(request, env, folderMatch[1]);
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

  const putIntelligenceMatch = url.pathname.match(/^\/v1\/recordings\/([^/]+)\/intelligence\/([^/]+)$/);
  if (putIntelligenceMatch && request.method === "PUT") {
    return putIntelligence(request, env, putIntelligenceMatch[1], putIntelligenceMatch[2]);
  }

  const getIntelligenceMatch = url.pathname.match(/^\/v1\/recordings\/([^/]+)\/intelligence\/([^/]+)\/([^/]+)$/);
  if (getIntelligenceMatch && request.method === "GET") {
    return getIntelligence(env, getIntelligenceMatch[1], getIntelligenceMatch[2], getIntelligenceMatch[3]);
  }

  const putMeetingEditMatch = url.pathname.match(/^\/v1\/meeting-edits\/([^/]+)$/);
  if (putMeetingEditMatch && request.method === "PUT") {
    return putMeetingEdit(request, env, putMeetingEditMatch[1]);
  }

  return jsonError(404, "not_found", "Endpoint was not found.");
}

const AI_SETTINGS_LIMIT_BYTES = 16 * 1024;
const AI_PREFERENCE_FIELDS = new Set([
  "schemaVersion", "modelID", "enhancementModelID", "transcriptionModelID", "outputLanguage",
  "autoGenerate", "transcriptCleanupEnabled", "modifiedAt", "mutationID",
]);

function exactObject(value, fields, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).some((key) => !fields.has(key))) {
    throw new HttpError(400, "invalid_ai_settings", `${label} contains unsupported fields.`);
  }
}

function exactPlainObject(value, fields, label, code) {
  if (!isPlainObject(value)) {
    throw new HttpError(400, code, `${label} must be a JSON object.`);
  }
  for (const field of Object.keys(value)) {
    if (!fields.has(field)) {
      throw new HttpError(400, code, `${label} contains unsupported field ${field}.`);
    }
  }
}

function requireFields(value, fields, label, code, nullableFields = new Set()) {
  for (const field of fields) {
    if (!Object.hasOwn(value, field) && !nullableFields.has(field)) {
      throw new HttpError(400, code, `${label} is missing ${field}.`);
    }
  }
}

function normalizeNullableFields(value, nullableFields) {
  const normalized = { ...value };
  for (const field of nullableFields) {
    if (!Object.hasOwn(normalized, field)) {
      normalized[field] = null;
    }
  }
  return normalized;
}

function validateAIPreferences(value, previousPreferences = null) {
  exactObject(value, AI_PREFERENCE_FIELDS, "AI preferences");
  const normalized = { ...value };
  if (!Object.hasOwn(normalized, "enhancementModelID")) {
    normalized.enhancementModelID = previousPreferences?.enhancementModelID ?? "";
  }
  if (!Object.hasOwn(normalized, "transcriptCleanupEnabled")) {
    normalized.transcriptCleanupEnabled = previousPreferences?.transcriptCleanupEnabled ?? true;
  }
  const validModelID = (id) => typeof id === "string" && id.length <= 256 &&
    (id === "" || /^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$/.test(id));
  if (normalized.schemaVersion !== 1 || !validModelID(normalized.modelID) ||
      !validModelID(normalized.enhancementModelID) || !validModelID(normalized.transcriptionModelID) ||
      !["ko", "en", "source"].includes(normalized.outputLanguage) ||
      typeof normalized.autoGenerate !== "boolean" || typeof normalized.transcriptCleanupEnabled !== "boolean" ||
      !Number.isSafeInteger(normalized.modifiedAt) || normalized.modifiedAt < 0) {
    throw new HttpError(400, "invalid_ai_settings", "AI preference values are invalid.");
  }
  validateUUID(normalized.mutationID, "settings mutation ID");
  return normalized;
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
  const existingSettings = await env.DB.prepare("SELECT preferences_json FROM ai_settings WHERE id = 1").first();
  const existingPreferences = existingSettings ? JSON.parse(existingSettings.preferences_json) : null;
  const preferences = candidate.preferences == null ? null : validateAIPreferences(candidate.preferences, existingPreferences);
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

async function getProfile(env) {
  requireBindings(env);
  const row = await env.DB.prepare("SELECT profile_json FROM text_profile WHERE id = 1").first();
  return json({ profile: row ? JSON.parse(row.profile_json) : null });
}

async function putProfile(request, env) {
  requireBindings(env);
  assertBodySize(request, PROFILE_LIMIT_BYTES, "Profile must not exceed 64 KiB.");
  const text = await readLimitedText(request, PROFILE_LIMIT_BYTES, "Profile must not exceed 64 KiB.");
  let candidate;
  try {
    candidate = JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_json", "Profile must be valid JSON.");
  }
  exactPlainObject(candidate, PROFILE_BODY_FIELDS, "Profile request", "invalid_profile");
  if (candidate.profile !== null) {
    const profile = validateProfile(candidate.profile);
    await env.DB.prepare(
      `INSERT INTO text_profile (id, profile_json, modified_at, mutation_id) VALUES (1, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET profile_json = excluded.profile_json,
         modified_at = excluded.modified_at, mutation_id = excluded.mutation_id
       WHERE excluded.modified_at > text_profile.modified_at
          OR (excluded.modified_at = text_profile.modified_at AND excluded.mutation_id > text_profile.mutation_id)`,
    ).bind(JSON.stringify(profile), profile.modifiedAt, profile.mutationID).run();
  }
  return getProfile(env);
}

async function listIntelligence(env, url) {
  requireBindings(env);
  const cursor = url.searchParams.get("cursor");
  if (cursor !== null && !NOTE_CURSOR_PATTERN.test(cursor)) {
    throw new HttpError(400, "invalid_cursor", "cursor must be UPPERCASE-UUID:0000000001.");
  }

  const result = await env.DB.prepare(
    `SELECT recording_id, audio_version, generated_at_millis, revision, byte_count, sync_key
       FROM meeting_intelligence
      WHERE (? IS NULL OR sync_key > ?)
      ORDER BY sync_key ASC
      LIMIT ?`,
  )
    .bind(cursor, cursor, PAGE_SIZE + 1)
    .all();
  const rows = result.results ?? [];
  const page = rows.slice(0, PAGE_SIZE);
  const intelligence = page.map(noteDescriptorFromRow);
  const nextCursor = rows.length > PAGE_SIZE ? page[page.length - 1].sync_key : null;
  return json({ intelligence, nextCursor });
}

async function putIntelligence(request, env, pathID, pathAudioVersion) {
  requireBindings(env);
  validateUUID(pathID, "recording id");
  const audioVersion = parseAudioVersion(pathAudioVersion);
  assertBodySize(request, INTELLIGENCE_LIMIT_BYTES, "Meeting intelligence must not exceed 4 MiB.");

  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new HttpError(415, "unsupported_media_type", "Meeting intelligence uploads must use Content-Type application/json.");
  }

  const bytes = await readLimitedBytes(request, INTELLIGENCE_LIMIT_BYTES, "Meeting intelligence must not exceed 4 MiB.");
  if (bytes.byteLength === 0) {
    throw new HttpError(400, "invalid_intelligence", "Meeting intelligence document body is required.");
  }
  let candidate;
  try {
    candidate = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new HttpError(400, "invalid_json", "Meeting intelligence document must be valid JSON.");
  }

  const document = validateIntelligenceDocument(candidate, pathID, audioVersion);
  const recording = await env.DB.prepare(
    `SELECT id, audio_version
       FROM recordings
      WHERE id = ?`,
  )
    .bind(pathID)
    .first();
  if (!recording) {
    throw new HttpError(409, "missing_recording", "Recording metadata must exist before publishing meeting intelligence.");
  }
  if (recording.audio_version !== audioVersion) {
    throw new HttpError(409, "audio_version_mismatch", "Meeting intelligence audioVersion must match the current recording metadata.");
  }

  const revision = await sha256Hex(bytes);
  const key = intelligenceKey(pathID, audioVersion, revision);
  const putResult = await env.AUDIO.put(key, bytes, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: {
      contentType: "application/json",
      cacheControl: "no-store",
    },
  });
  if (putResult === null && !(await env.AUDIO.head(key))) {
    throw new HttpError(409, "immutable_write_conflict", "Meeting intelligence object could not be stored immutably.");
  }

  const syncKey = noteSyncKey(pathID, audioVersion);
  await env.DB.prepare(
    `INSERT INTO meeting_intelligence
       (recording_id, audio_version, generated_at_millis, mutation_id, revision, byte_count, object_key, sync_key)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(recording_id, audio_version) DO UPDATE SET
       generated_at_millis = excluded.generated_at_millis,
       mutation_id = excluded.mutation_id,
       revision = excluded.revision,
       byte_count = excluded.byte_count,
       object_key = excluded.object_key,
       sync_key = excluded.sync_key
     WHERE excluded.generated_at_millis > meeting_intelligence.generated_at_millis
        OR (excluded.generated_at_millis = meeting_intelligence.generated_at_millis
            AND excluded.mutation_id > meeting_intelligence.mutation_id)`,
  )
    .bind(pathID, audioVersion, document.modifiedAt, document.mutationID, revision, bytes.byteLength, key, syncKey)
    .run();

  const winner = await env.DB.prepare(
    `SELECT recording_id, audio_version, generated_at_millis, revision, byte_count, sync_key
       FROM meeting_intelligence
      WHERE recording_id = ? AND audio_version = ?`,
  )
    .bind(pathID, audioVersion)
    .first();
  return json({ intelligence: noteDescriptorFromRow(winner) });
}

async function getIntelligence(env, pathID, pathAudioVersion, pathRevision) {
  requireBindings(env);
  validateUUID(pathID, "recording id");
  const audioVersion = parseAudioVersion(pathAudioVersion);
  if (!REVISION_PATTERN.test(pathRevision)) {
    throw new HttpError(400, "invalid_revision", "revision must be a lowercase 64-character SHA-256 hex string.");
  }

  const row = await env.DB.prepare(
    `SELECT object_key, byte_count
       FROM meeting_intelligence
      WHERE recording_id = ? AND audio_version = ? AND revision = ?`,
  )
    .bind(pathID, audioVersion, pathRevision)
    .first();
  if (!row) {
    throw new HttpError(404, "not_found", "Meeting intelligence descriptor was not found.");
  }

  const object = await env.AUDIO.get(row.object_key);
  if (!object) {
    throw new HttpError(404, "not_found", "Meeting intelligence object was not found.");
  }
  const headers = new Headers();
  headers.set("Content-Type", "application/json");
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Length", String(row.byte_count));
  return new Response(object.body, { status: 200, headers });
}

async function listMeetingEdits(env, url) {
  requireBindings(env);
  const afterText = url.searchParams.get("after") ?? "0";
  const after = Number(afterText);
  if (!Number.isSafeInteger(after) || after < 0 || String(after) !== afterText) {
    throw new HttpError(400, "invalid_cursor", "after must be a nonnegative integer.");
  }
  const result = await env.DB.prepare(
    `SELECT sequence, payload_json
       FROM meeting_edits
      WHERE sequence > ?
      ORDER BY sequence ASC
      LIMIT ?`,
  )
    .bind(after, PAGE_SIZE + 1)
    .all();
  const rows = result.results ?? [];
  const page = rows.slice(0, PAGE_SIZE);
  const entries = page.map((row) => ({ sequence: row.sequence, edit: JSON.parse(row.payload_json) }));
  const nextCursor = rows.length > PAGE_SIZE ? page[page.length - 1].sequence : null;
  return json({ entries, nextCursor });
}

async function putMeetingEdit(request, env, pathID) {
  requireBindings(env);
  validateUUID(pathID, "meeting edit id");
  assertBodySize(request, MEETING_EDIT_LIMIT_BYTES, "Meeting edit must not exceed 16 KiB.");

  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new HttpError(415, "unsupported_media_type", "Meeting edit uploads must use Content-Type application/json.");
  }

  const text = await readLimitedText(request, MEETING_EDIT_LIMIT_BYTES, "Meeting edit must not exceed 16 KiB.");
  let candidate;
  try {
    candidate = JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_json", "Meeting edit must be valid JSON.");
  }
  const edit = validateMeetingEdit(candidate, pathID);
  const payload = JSON.stringify(edit);

  const recording = await env.DB.prepare(
    `SELECT id, audio_version
       FROM recordings
      WHERE id = ?`,
  )
    .bind(edit.recordingID)
    .first();
  if (!recording) {
    throw new HttpError(409, "missing_recording", "Recording metadata must exist before publishing meeting edits.");
  }
  if (recording.audio_version !== edit.audioVersion) {
    throw new HttpError(409, "audio_version_mismatch", "Meeting edit audioVersion must match the current recording metadata.");
  }

  const existing = await env.DB.prepare("SELECT sequence, payload_json FROM meeting_edits WHERE id = ?")
    .bind(pathID)
    .first();
  if (existing) {
    if (existing.payload_json !== payload) {
      throw new HttpError(409, "edit_conflict", "Meeting edit id already exists with a different payload.");
    }
    return json({ entry: { sequence: existing.sequence, edit: JSON.parse(existing.payload_json) } });
  }

  await env.DB.prepare(
    `INSERT OR IGNORE INTO meeting_edits (id, recording_id, audio_version, payload_json)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(pathID, edit.recordingID, edit.audioVersion, payload)
    .run();
  const row = await env.DB.prepare("SELECT sequence, payload_json FROM meeting_edits WHERE id = ?")
    .bind(pathID)
    .first();
  if (!row) {
    throw new HttpError(409, "edit_conflict", "Meeting edit id could not be stored.");
  }
  if (row.payload_json !== payload) {
    throw new HttpError(409, "edit_conflict", "Meeting edit id already exists with a different payload.");
  }
  return json({ entry: { sequence: row.sequence, edit: JSON.parse(row.payload_json) } });
}

async function health(env) {
  requireBindings(env);
  await env.DB.prepare("SELECT id FROM recordings ORDER BY id ASC LIMIT 1").first();
  await env.DB.prepare("SELECT id FROM recording_folders ORDER BY id ASC LIMIT 1").first();
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

async function listFolders(env, url) {
  requireBindings(env);
  const cursor = url.searchParams.get("cursor");
  if (cursor !== null && !UUID_PATTERN.test(cursor)) {
    throw new HttpError(400, "invalid_cursor", "cursor must be a canonical uppercase UUID.");
  }

  const result = await env.DB.prepare(
    `SELECT id, metadata_json, modified_at, mutation_id, deleted_at
       FROM recording_folders
      WHERE (? IS NULL OR id > ?)
      ORDER BY id ASC
      LIMIT ?`,
  )
    .bind(cursor, cursor, PAGE_SIZE + 1)
    .all();
  const rows = result.results ?? [];
  const page = rows.slice(0, PAGE_SIZE);
  const folders = page.map((row) => JSON.parse(row.metadata_json));
  const nextCursor = rows.length > PAGE_SIZE ? page[page.length - 1].id : null;
  return json({ folders, nextCursor });
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

  const existing = await env.DB.prepare(
    `SELECT id, metadata_json, modified_at, mutation_id, audio_version, deleted_at
       FROM recordings
      WHERE id = ?`,
  )
    .bind(pathID)
    .first();
  const previousRecording = existing ? JSON.parse(existing.metadata_json) : null;
  const recording = validateRecording(candidate, pathID, previousRecording);
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

async function putFolder(request, env, pathID) {
  requireBindings(env);
  validateUUID(pathID, "folder id");
  assertBodySize(request, FOLDERS_LIMIT_BYTES, "Folder metadata must not exceed 64 KiB.");

  const body = await readLimitedText(request, FOLDERS_LIMIT_BYTES, "Folder metadata must not exceed 64 KiB.");
  let candidate;
  try {
    candidate = JSON.parse(body);
  } catch {
    throw new HttpError(400, "invalid_json", "Folder metadata must be valid JSON.");
  }

  const existing = await env.DB.prepare(
    `SELECT id, metadata_json, modified_at, mutation_id, deleted_at
       FROM recording_folders
      WHERE id = ?`,
  )
    .bind(pathID)
    .first();
  const previousFolder = existing ? JSON.parse(existing.metadata_json) : null;
  const folder = validateFolder(candidate, pathID, previousFolder);
  await env.DB.prepare(
    `INSERT INTO recording_folders (id, metadata_json, modified_at, mutation_id, deleted_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       metadata_json = excluded.metadata_json,
       modified_at = excluded.modified_at,
       mutation_id = excluded.mutation_id,
       deleted_at = excluded.deleted_at
     WHERE excluded.modified_at > recording_folders.modified_at
        OR (excluded.modified_at = recording_folders.modified_at
            AND excluded.mutation_id > recording_folders.mutation_id)`,
  )
    .bind(pathID, JSON.stringify(folder), folder.modifiedAt, folder.mutationID, folder.deletedAt)
    .run();

  const winner = await env.DB.prepare(
    `SELECT id, metadata_json, modified_at, mutation_id, deleted_at
       FROM recording_folders
      WHERE id = ?`,
  )
    .bind(pathID)
    .first();
  return json({ folder: JSON.parse(winner.metadata_json) });
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

  const note = await validateMeetingNotesDocument(candidate, pathID, audioVersion);
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

function validateRecording(value, pathID, previousRecording = null) {
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
    if (!Object.hasOwn(normalized, field) && !RECORDING_OPTIONAL_FIELDS.has(field)) {
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
  if (Object.hasOwn(normalized, "folderAssignment")) {
    normalized.folderAssignment = validateFolderAssignment(normalized.folderAssignment);
  } else if (previousRecording && Object.hasOwn(previousRecording, "folderAssignment")) {
    normalized.folderAssignment = previousRecording.folderAssignment;
  }
  validateInteger(normalized.modifiedAt, "modifiedAt", 0, Number.MAX_SAFE_INTEGER);
  validateUUID(normalized.mutationID, "mutationID");

  return normalized;
}

function validateFolderAssignment(value) {
  exactPlainObject(value, FOLDER_ASSIGNMENT_FIELDS, "Folder assignment", "invalid_recording");
  if (!Object.hasOwn(value, "id")) {
    throw new HttpError(400, "invalid_recording", "Folder assignment is missing id.");
  }
  if (value.id !== null) {
    validateUUID(value.id, "folder assignment id");
  }
  return { id: value.id };
}

function validateFolder(value, pathID, previousFolder = null) {
  if (!isPlainObject(value)) {
    throw new HttpError(400, "invalid_folder", "Folder metadata must be a JSON object.");
  }
  const normalized = { ...value };
  for (const field of FOLDER_NULL_FIELDS) {
    if (!Object.hasOwn(normalized, field)) {
      normalized[field] = null;
    }
  }
  for (const field of FOLDER_FIELDS) {
    if (!Object.hasOwn(normalized, field) && !FOLDER_OPTIONAL_FIELDS.has(field)) {
      throw new HttpError(400, "invalid_folder", `Folder metadata is missing ${field}.`);
    }
  }
  for (const field of Object.keys(normalized)) {
    if (!FOLDER_FIELDS.has(field)) {
      throw new HttpError(400, "invalid_folder", `Folder metadata contains unknown field ${field}.`);
    }
  }

  validateInteger(normalized.schemaVersion, "schemaVersion", 1, SCHEMA_VERSION, "invalid_folder");
  validateUUID(normalized.id, "id");
  if (normalized.id !== pathID) {
    throw new HttpError(400, "invalid_folder", "Folder id must match the URL.");
  }
  validateString(normalized.name, "name", 1, 512, "invalid_folder");
  const characterCount = Array.from(new Intl.Segmenter("und", { granularity: "grapheme" }).segment(normalized.name)).length;
  if (characterCount > 120) {
    throw new HttpError(400, "invalid_folder", "Folder name exceeds 120 characters.");
  }
  if (normalized.name.trim() !== normalized.name || normalized.name.length === 0) {
    throw new HttpError(400, "invalid_folder", "Folder name must be trimmed and non-empty.");
  }
  if (new TextEncoder().encode(normalized.name).byteLength > 512) {
    throw new HttpError(400, "invalid_folder", "Folder name exceeds 512 UTF-8 bytes.");
  }
  validateISODate(normalized.createdAt, "createdAt", false, "invalid_folder");
  validateInteger(normalized.modifiedAt, "modifiedAt", 0, Number.MAX_SAFE_INTEGER, "invalid_folder");
  validateUUID(normalized.mutationID, "folder mutation ID");
  validateISODate(normalized.deletedAt, "deletedAt", true, "invalid_folder");
  if (Object.hasOwn(normalized, "sortOrder")) {
    if (normalized.sortOrder !== null) {
      validateInteger(normalized.sortOrder, "sortOrder", 0, Number.MAX_SAFE_INTEGER, "invalid_folder");
    }
  } else if (previousFolder && Object.hasOwn(previousFolder, "sortOrder")) {
    normalized.sortOrder = previousFolder.sortOrder;
  }
  return normalized;
}

async function validateMeetingNotesDocument(value, pathID, audioVersion) {
  if (!isPlainObject(value)) {
    throw new HttpError(400, "invalid_notes", "Meeting notes document must be a JSON object.");
  }
  for (const field of NOTE_FIELDS) {
    if (!Object.hasOwn(value, field)) {
      if (["costUSD", "speakerTranscript", "enhancement", "transcriptCleanup"].includes(field)) {
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
  if (value.speakerTranscript != null) {
    validateTranscript(value.speakerTranscript, pathID, audioVersion);
  }
  if (value.enhancement != null) {
    const fields = new Set(["modelID", "instructions"]);
    exactPlainObject(value.enhancement, fields, "Enhancement", "invalid_notes");
    requireFields(value.enhancement, fields, "Enhancement", "invalid_notes");
    validateString(value.enhancement.modelID, "enhancement modelID", 1, 512, "invalid_notes");
    validateString(value.enhancement.instructions, "enhancement instructions", 1, 8000, "invalid_notes");
    if (new TextEncoder().encode(value.enhancement.instructions).byteLength > 8000) {
      throw new HttpError(400, "invalid_notes", "Enhancement instructions exceed 8000 UTF-8 bytes.");
    }
  }
  if (value.transcriptCleanup != null) {
    await validateTranscriptCleanup(value.transcriptCleanup, value.transcript, value.speakerTranscript ?? null);
  }
  return value;
}

async function validateTranscriptCleanup(value, transcript, speakerTranscript) {
  exactPlainObject(value, TRANSCRIPT_CLEANUP_FIELDS, "Transcript cleanup", "invalid_notes");
  requireFields(value, TRANSCRIPT_CLEANUP_FIELDS, "Transcript cleanup", "invalid_notes");
  validateInteger(value.schemaVersion, "transcriptCleanup.schemaVersion", 1, SCHEMA_VERSION, "invalid_notes");
  validateString(value.modelID, "transcript cleanup modelID", 1, 512, "invalid_notes");
  if (!["plain", "speakers"].includes(value.sourceKind)) {
    throw new HttpError(400, "invalid_notes", "Transcript cleanup sourceKind is invalid.");
  }
  if (typeof value.sourceHash !== "string" || !CLEANUP_SOURCE_HASH_PATTERN.test(value.sourceHash)) {
    throw new HttpError(400, "invalid_notes", "Transcript cleanup sourceHash must be a lowercase SHA-256 hex digest.");
  }
  if (!Array.isArray(value.passages) || value.passages.length > 20_000) {
    throw new HttpError(400, "invalid_notes", "Transcript cleanup passages must be an array of up to 20000 entries.");
  }

  const expectedIDs = value.sourceKind === "plain" ? plainCleanupSourceIDs(transcript) : speakerCleanupSourceIDs(speakerTranscript);
  if (value.passages.length !== expectedIDs.length) {
    throw new HttpError(400, "invalid_notes", "Transcript cleanup passages must match the source transcript.");
  }

  let totalBytes = 0;
  let hasNonEmptyText = false;
  const seenIDs = new Set();
  for (const [index, passage] of value.passages.entries()) {
    exactPlainObject(passage, TRANSCRIPT_CLEANUP_PASSAGE_FIELDS, "Transcript cleanup passage", "invalid_notes");
    requireFields(passage, TRANSCRIPT_CLEANUP_PASSAGE_FIELDS, "Transcript cleanup passage", "invalid_notes");
    validateString(passage.id, "transcript cleanup passage id", 1, 512, "invalid_notes");
    if (seenIDs.has(passage.id) || passage.id !== expectedIDs[index]) {
      throw new HttpError(400, "invalid_notes", "Transcript cleanup passage ids must match the source transcript order.");
    }
    seenIDs.add(passage.id);
    validateString(passage.text, "transcript cleanup passage text", 0, 32 * 1024, "invalid_notes");
    const byteLength = new TextEncoder().encode(passage.text).byteLength;
    if (byteLength > 32 * 1024) {
      throw new HttpError(400, "invalid_notes", "Transcript cleanup passage text exceeds 32 KiB.");
    }
    totalBytes += byteLength;
    if (totalBytes > 1024 * 1024) {
      throw new HttpError(400, "invalid_notes", "Transcript cleanup text exceeds 1 MiB.");
    }
    if (passage.text.trim().length > 0) {
      hasNonEmptyText = true;
    }
  }
  if (!hasNonEmptyText) {
    throw new HttpError(400, "invalid_notes", "Transcript cleanup must include at least one non-empty passage.");
  }

  const expectedHash = value.sourceKind === "plain"
    ? await sha256Text(`plain-v1\n${transcript}`)
    : await sha256Text(`speakers-v1\n${speakerHashPayload(speakerTranscript)}`);
  if (value.sourceHash !== expectedHash) {
    throw new HttpError(400, "invalid_notes", "Transcript cleanup sourceHash does not match the source transcript.");
  }
}

function plainCleanupSourceIDs(transcript) {
  const ids = [];
  for (const paragraph of transcript.split("\n\n")) {
    const scalars = Array.from(paragraph);
    for (let offset = 0; offset < scalars.length; offset += 2000) {
      if (scalars.slice(offset, offset + 2000).length > 0) {
        ids.push(`p${ids.length}`);
      }
    }
  }
  return ids;
}

function speakerCleanupSourceIDs(speakerTranscript) {
  if (speakerTranscript == null) {
    throw new HttpError(400, "invalid_notes", "Speaker transcript cleanup requires an embedded speaker transcript.");
  }
  return speakerTranscript.turns.map((turn) => turn.id);
}

function speakerHashPayload(speakerTranscript) {
  return speakerTranscript.turns.map((turn) => `${utf8Length(turn.id)}:${turn.id}${utf8Length(turn.text)}:${turn.text}`).join("");
}

function validateProfile(value) {
  exactPlainObject(value, PROFILE_FIELDS, "Profile", "invalid_profile");
  requireFields(value, PROFILE_FIELDS, "Profile", "invalid_profile", new Set(["automaticallyAnalyze"]));
  const normalized = { automaticallyAnalyze: false, ...value };
  validateInteger(normalized.schemaVersion, "schemaVersion", 1, SCHEMA_VERSION, "invalid_profile");
  validateString(normalized.displayName, "displayName", 0, 256, "invalid_profile");
  validateString(normalized.role, "role", 0, 256, "invalid_profile");
  validateBooleanCode(normalized.automaticallyAnalyze, "automaticallyAnalyze", "invalid_profile");
  validateInteger(normalized.modifiedAt, "modifiedAt", 0, Number.MAX_SAFE_INTEGER, "invalid_profile");
  validateUUID(normalized.mutationID, "profile mutation ID");
  validateStringArray(normalized.aliases, "aliases", 32, 256, "invalid_profile");
  validateProfileTerms(normalized.terms);
  return normalized;
}

function validateProfileTerms(terms) {
  if (!Array.isArray(terms) || terms.length > 512) {
    throw new HttpError(400, "invalid_profile", "terms must be an array of up to 512 entries.");
  }
  const seen = new Set();
  for (const term of terms) {
    exactPlainObject(term, PROFILE_TERM_FIELDS, "Profile term", "invalid_profile");
    requireFields(term, PROFILE_TERM_FIELDS, "Profile term", "invalid_profile");
    validateUUID(term.id, "profile term id");
    if (seen.has(term.id)) {
      throw new HttpError(400, "invalid_profile", "Profile term ids must be unique.");
    }
    seen.add(term.id);
    validateString(term.term, "term", 1, 256, "invalid_profile");
    validateString(term.spokenAs, "spokenAs", 0, 256, "invalid_profile");
    validateString(term.meaning, "meaning", 0, 1024, "invalid_profile");
    if (!PROFILE_TERM_CATEGORIES.has(term.category)) {
      throw new HttpError(400, "invalid_profile", "Profile term category is invalid.");
    }
  }
}

function validateIntelligenceDocument(value, pathID, audioVersion) {
  exactPlainObject(value, INTELLIGENCE_FIELDS, "Meeting intelligence document", "invalid_intelligence");
  requireFields(value, INTELLIGENCE_FIELDS, "Meeting intelligence document", "invalid_intelligence", new Set(["insights"]));
  const normalized = normalizeNullableFields(value, new Set(["insights"]));
  validateInteger(normalized.schemaVersion, "schemaVersion", 1, SCHEMA_VERSION, "invalid_intelligence");
  validateUUID(normalized.recordingID, "recordingID");
  if (normalized.recordingID !== pathID) {
    throw new HttpError(400, "invalid_intelligence", "recordingID must match the URL.");
  }
  validateInteger(normalized.audioVersion, "audioVersion", 1, 2_147_483_647, "invalid_intelligence");
  if (normalized.audioVersion !== audioVersion) {
    throw new HttpError(400, "invalid_intelligence", "audioVersion must match the URL.");
  }
  validateInteger(normalized.modifiedAt, "modifiedAt", 0, Number.MAX_SAFE_INTEGER, "invalid_intelligence");
  validateUUID(normalized.mutationID, "intelligence mutation ID");
  validateString(normalized.projectName, "projectName", 0, 512, "invalid_intelligence");
  validateString(normalized.analysisModelID, "analysisModelID", 1, 512, "invalid_intelligence");

  const { speakerIDs, turnIDs } = validateTranscript(normalized.transcript, pathID, audioVersion);
  const actionIDs = normalized.insights === null
    ? new Set()
    : validateInsights(normalized.insights, speakerIDs, turnIDs);
  validateActionStates(normalized.actionStates, actionIDs);
  return normalized;
}

function validateTranscript(value, pathID, audioVersion) {
  exactPlainObject(value, TRANSCRIPT_FIELDS, "Transcript", "invalid_intelligence");
  requireFields(value, TRANSCRIPT_FIELDS, "Transcript", "invalid_intelligence");
  validateInteger(value.schemaVersion, "transcript.schemaVersion", 1, SCHEMA_VERSION, "invalid_intelligence");
  validateUUID(value.recordingID, "transcript recordingID");
  if (value.recordingID !== pathID) {
    throw new HttpError(400, "invalid_intelligence", "Transcript recordingID must match the URL.");
  }
  validateInteger(value.audioVersion, "transcript.audioVersion", 1, 2_147_483_647, "invalid_intelligence");
  if (value.audioVersion !== audioVersion) {
    throw new HttpError(400, "invalid_intelligence", "Transcript audioVersion must match the URL.");
  }
  validateString(value.transcriptionModelID, "transcriptionModelID", 1, 512, "invalid_intelligence");
  const speakerIDs = validateSpeakers(value.speakers);
  const turnIDs = validateTurns(value.turns, speakerIDs);
  return { speakerIDs, turnIDs };
}

function validateSpeakers(speakers) {
  if (!Array.isArray(speakers) || speakers.length > 512) {
    throw new HttpError(400, "invalid_intelligence", "speakers must be an array of up to 512 entries.");
  }
  const speakerIDs = new Set();
  for (const speaker of speakers) {
    exactPlainObject(speaker, SPEAKER_FIELDS, "Speaker", "invalid_intelligence");
    requireFields(speaker, SPEAKER_FIELDS, "Speaker", "invalid_intelligence");
    validateIdentifier(speaker.id, "speaker id", "invalid_intelligence");
    if (speakerIDs.has(speaker.id)) {
      throw new HttpError(400, "invalid_intelligence", "Speaker ids must be unique.");
    }
    speakerIDs.add(speaker.id);
    validateString(speaker.name, "speaker name", 0, 256, "invalid_intelligence");
    validateBooleanCode(speaker.isOwner, "isOwner", "invalid_intelligence");
    validateBooleanCode(speaker.manuallyAssigned, "manuallyAssigned", "invalid_intelligence");
  }
  return speakerIDs;
}

function validateTurns(turns, speakerIDs) {
  if (!Array.isArray(turns) || turns.length > 20_000) {
    throw new HttpError(400, "invalid_intelligence", "turns must be an array of up to 20000 entries.");
  }
  const turnIDs = new Set();
  for (const turn of turns) {
    const normalized = normalizeNullableFields(turn, new Set(["speakerID"]));
    exactPlainObject(normalized, TURN_FIELDS, "Turn", "invalid_intelligence");
    requireFields(normalized, TURN_FIELDS, "Turn", "invalid_intelligence");
    validateIdentifier(normalized.id, "turn id", "invalid_intelligence");
    if (turnIDs.has(normalized.id)) {
      throw new HttpError(400, "invalid_intelligence", "Turn ids must be unique.");
    }
    turnIDs.add(normalized.id);
    validateFiniteNumber(normalized.start, "turn start", 0, "invalid_intelligence");
    validateFiniteNumber(normalized.end, "turn end", 0, "invalid_intelligence");
    if (normalized.end < normalized.start) {
      throw new HttpError(400, "invalid_intelligence", "Turn end must be greater than or equal to start.");
    }
    if (normalized.speakerID !== null) {
      validateIdentifier(normalized.speakerID, "turn speakerID", "invalid_intelligence");
      if (!speakerIDs.has(normalized.speakerID)) {
        throw new HttpError(400, "invalid_intelligence", "Turn speakerID must reference an existing speaker.");
      }
    }
    validateString(normalized.text, "turn text", 0, INTELLIGENCE_LIMIT_BYTES, "invalid_intelligence");
  }
  return turnIDs;
}

function validateInsights(value, speakerIDs, turnIDs) {
  exactPlainObject(value, INSIGHTS_FIELDS, "Insights", "invalid_intelligence");
  requireFields(value, INSIGHTS_FIELDS, "Insights", "invalid_intelligence");
  validateInteger(value.schemaVersion, "insights.schemaVersion", 1, SCHEMA_VERSION, "invalid_intelligence");
  const actionIDs = validateActions(value.actions, speakerIDs, turnIDs);
  validateQuestions(value.questions, turnIDs);
  validateDecisions(value.decisions, speakerIDs, turnIDs);
  return actionIDs;
}

function validateActions(actions, speakerIDs, turnIDs) {
  if (!Array.isArray(actions) || actions.length > 2048) {
    throw new HttpError(400, "invalid_intelligence", "actions must be an array of up to 2048 entries.");
  }
  const actionIDs = new Set();
  for (const action of actions) {
    const normalized = normalizeNullableFields(action, new Set(["actorSpeakerID", "targetSpeakerID", "dueText"]));
    exactPlainObject(normalized, ACTION_FIELDS, "Action", "invalid_intelligence");
    requireFields(normalized, ACTION_FIELDS, "Action", "invalid_intelligence");
    validateIdentifier(normalized.id, "action id", "invalid_intelligence");
    if (actionIDs.has(normalized.id)) {
      throw new HttpError(400, "invalid_intelligence", "Action ids must be unique.");
    }
    actionIDs.add(normalized.id);
    if (!ACTION_KINDS.has(normalized.kind)) {
      throw new HttpError(400, "invalid_intelligence", "Action kind is invalid.");
    }
    validateString(normalized.text, "action text", 1, 4096, "invalid_intelligence");
    validateNullableReference(normalized.actorSpeakerID, speakerIDs, "actorSpeakerID");
    validateNullableReference(normalized.targetSpeakerID, speakerIDs, "targetSpeakerID");
    if (normalized.dueText !== null) {
      validateString(normalized.dueText, "dueText", 0, 1024, "invalid_intelligence");
    }
    validateReferenceArray(normalized.evidenceTurnIDs, turnIDs, "evidenceTurnIDs");
  }
  return actionIDs;
}

function validateQuestions(questions, turnIDs) {
  if (!Array.isArray(questions) || questions.length > 2048) {
    throw new HttpError(400, "invalid_intelligence", "questions must be an array of up to 2048 entries.");
  }
  const questionIDs = new Set();
  for (const question of questions) {
    const normalized = normalizeNullableFields(question, new Set(["answer"]));
    exactPlainObject(normalized, QUESTION_FIELDS, "Question", "invalid_intelligence");
    requireFields(normalized, QUESTION_FIELDS, "Question", "invalid_intelligence");
    validateIdentifier(normalized.id, "question id", "invalid_intelligence");
    if (questionIDs.has(normalized.id)) {
      throw new HttpError(400, "invalid_intelligence", "Question ids must be unique.");
    }
    questionIDs.add(normalized.id);
    validateString(normalized.question, "question", 1, 4096, "invalid_intelligence");
    validateReferenceArray(normalized.questionTurnIDs, turnIDs, "questionTurnIDs");
    if (normalized.answer !== null) {
      validateString(normalized.answer, "answer", 0, 4096, "invalid_intelligence");
    }
    validateReferenceArray(normalized.answerTurnIDs, turnIDs, "answerTurnIDs");
    if (!QUESTION_STATUSES.has(normalized.status)) {
      throw new HttpError(400, "invalid_intelligence", "Question status is invalid.");
    }
  }
}

function validateDecisions(decisions, speakerIDs, turnIDs) {
  if (!Array.isArray(decisions) || decisions.length > 2048) {
    throw new HttpError(400, "invalid_intelligence", "decisions must be an array of up to 2048 entries.");
  }
  const decisionIDs = new Set();
  for (const decision of decisions) {
    exactPlainObject(decision, DECISION_FIELDS, "Decision", "invalid_intelligence");
    requireFields(decision, DECISION_FIELDS, "Decision", "invalid_intelligence");
    validateIdentifier(decision.id, "decision id", "invalid_intelligence");
    if (decisionIDs.has(decision.id)) {
      throw new HttpError(400, "invalid_intelligence", "Decision ids must be unique.");
    }
    decisionIDs.add(decision.id);
    validateString(decision.topic, "decision topic", 1, 4096, "invalid_intelligence");
    if (!DECISION_STATUSES.has(decision.status)) {
      throw new HttpError(400, "invalid_intelligence", "Decision status is invalid.");
    }
    if (!Array.isArray(decision.steps) || decision.steps.length > 512) {
      throw new HttpError(400, "invalid_intelligence", "Decision steps must be an array of up to 512 entries.");
    }
    for (const step of decision.steps) {
      const normalized = normalizeNullableFields(step, new Set(["speakerID"]));
      exactPlainObject(normalized, DECISION_STEP_FIELDS, "Decision step", "invalid_intelligence");
      requireFields(normalized, DECISION_STEP_FIELDS, "Decision step", "invalid_intelligence");
      if (!DECISION_STEP_KINDS.has(normalized.kind)) {
        throw new HttpError(400, "invalid_intelligence", "Decision step kind is invalid.");
      }
      validateString(normalized.text, "decision step text", 1, 4096, "invalid_intelligence");
      validateNullableReference(normalized.speakerID, speakerIDs, "decision speakerID");
      validateReferenceArray(normalized.evidenceTurnIDs, turnIDs, "decision evidenceTurnIDs");
    }
  }
}

function validateActionStates(actionStates, actionIDs) {
  exactPlainObject(actionStates, new Set(Object.keys(actionStates ?? {})), "actionStates", "invalid_intelligence");
  for (const [actionID, state] of Object.entries(actionStates)) {
    if (!actionIDs.has(actionID)) {
      throw new HttpError(400, "invalid_intelligence", "actionStates keys must reference existing action ids.");
    }
    if (!ACTION_STATES.has(state)) {
      throw new HttpError(400, "invalid_intelligence", "actionStates values are invalid.");
    }
  }
}

function validateMeetingEdit(value, pathID) {
  exactPlainObject(value, MEETING_EDIT_FIELDS, "Meeting edit", "invalid_meeting_edit");
  requireFields(value, MEETING_EDIT_FIELDS, "Meeting edit", "invalid_meeting_edit");
  validateInteger(value.schemaVersion, "schemaVersion", 1, SCHEMA_VERSION, "invalid_meeting_edit");
  validateUUID(value.id, "meeting edit id");
  if (value.id !== pathID) {
    throw new HttpError(400, "invalid_meeting_edit", "Meeting edit id must match the URL.");
  }
  validateUUID(value.recordingID, "recordingID");
  validateInteger(value.audioVersion, "audioVersion", 1, 2_147_483_647, "invalid_meeting_edit");
  validateInteger(value.modifiedAt, "modifiedAt", 0, Number.MAX_SAFE_INTEGER, "invalid_meeting_edit");
  if (!MEETING_EDIT_KINDS.has(value.kind)) {
    throw new HttpError(400, "invalid_meeting_edit", "Meeting edit kind is invalid.");
  }
  validateEditTargetID(value.targetID, value.kind);
  validateEditValue(value.value, value.kind);
  return value;
}

function validateEditTargetID(value, kind) {
  if (typeof value !== "string" || value.length > 128 || !/^[\x20-\x7E]*$/.test(value)) {
    throw new HttpError(400, "invalid_meeting_edit", "targetID must be an ASCII string up to 128 characters.");
  }
  if (kind === "projectName") {
    if (value !== "") {
      throw new HttpError(400, "invalid_meeting_edit", "projectName edits must use an empty targetID.");
    }
    return;
  }
  if (value.length === 0) {
    throw new HttpError(400, "invalid_meeting_edit", "targetID is required for this edit kind.");
  }
}

function validateEditValue(value, kind) {
  validateString(value, "value", 0, 256, "invalid_meeting_edit");
  if (kind === "speakerOwner" && !["true", "false"].includes(value)) {
    throw new HttpError(400, "invalid_meeting_edit", "speakerOwner edits must use true or false.");
  }
  if (kind === "actionStatus" && !ACTION_STATES.has(value)) {
    throw new HttpError(400, "invalid_meeting_edit", "actionStatus edits must use open, done, or dismissed.");
  }
  if (kind === "turnSpeaker" && value !== "") {
    validateIdentifier(value, "turnSpeaker value", "invalid_meeting_edit");
  }
}

function validateReferenceArray(values, allowed, label) {
  if (!Array.isArray(values) || values.some((value) => typeof value !== "string")) {
    throw new HttpError(400, "invalid_intelligence", `${label} must be an array of strings.`);
  }
  for (const value of values) {
    if (!allowed.has(value)) {
      throw new HttpError(400, "invalid_intelligence", `${label} must reference existing turns.`);
    }
  }
}

function validateNullableReference(value, allowed, label) {
  if (value === null) {
    return;
  }
  validateIdentifier(value, label, "invalid_intelligence");
  if (!allowed.has(value)) {
    throw new HttpError(400, "invalid_intelligence", `${label} must reference an existing speaker.`);
  }
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

function validateBooleanCode(value, label, code) {
  if (typeof value !== "boolean") {
    throw new HttpError(400, code, `${label} must be a boolean.`);
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

function validateStringArray(value, label, maxEntries, maxLength, code) {
  if (!Array.isArray(value) || value.length > maxEntries) {
    throw new HttpError(400, code, `${label} must be an array of up to ${maxEntries} strings.`);
  }
  const seen = new Set();
  for (const item of value) {
    validateString(item, label, 0, maxLength, code);
    if (seen.has(item)) {
      throw new HttpError(400, code, `${label} entries must be unique.`);
    }
    seen.add(item);
  }
}

function validateIdentifier(value, label, code) {
  if (typeof value !== "string" || value.length < 1 || value.length > 256 || !/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(value)) {
    throw new HttpError(400, code, `${label} must be a stable string identifier.`);
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

async function sha256Text(text) {
  return sha256Hex(new TextEncoder().encode(text));
}

function utf8Length(text) {
  return new TextEncoder().encode(text).byteLength;
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

function intelligenceKey(id, audioVersion, revision) {
  return `recordings/${id}/intelligence/${audioVersion}/${revision}.json`;
}

function noteSyncKey(id, audioVersion) {
  return `${id}:${String(audioVersion).padStart(10, "0")}`;
}
