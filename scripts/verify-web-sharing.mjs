// Run against a local Wrangler server after applying local D1 migrations.
// SHARE_TEST_BASE=http://127.0.0.1:8799 SHARE_TEST_TOKEN=... node scripts/verify-web-sharing.mjs
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const base = new URL(process.env.SHARE_TEST_BASE ?? "http://127.0.0.1:8799");
assert.ok(["127.0.0.1", "localhost", "[::1]"].includes(base.hostname), "This probe only modifies a local test server.");
const token = process.env.SHARE_TEST_TOKEN;
assert.ok(token, "Set SHARE_TEST_TOKEN to the local Worker's SYNC_TOKEN.");
const source = randomUUID().toUpperCase();
const path = `/v1/shares/${source}`;
const admin = (method, body) => fetch(new URL(path, base), {
  method, redirect: "error",
  headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
});
const publicURL = (value) => {
  const result = new URL(value);
  assert.equal(result.origin, base.origin);
  assert.match(result.pathname, /^\/s\/[A-Za-z0-9_-]{43}$/);
  return result;
};
let checks = 0;
const checkStatus = async (response, expected) => {
  assert.equal(response.status, expected, await response.clone().text());
  checks++;
  return response;
};

try {
  await checkStatus(await fetch(new URL(path, base)), 401);
  await checkStatus(await fetch(new URL("/v1/recordings", base)), 401);
  assert.deepEqual(await (await checkStatus(await admin("GET"), 200)).json(), { active: false });

  const before = Date.now();
  const created = await (await checkStatus(await admin("PUT", {
    title: "웹 공유 검증 <fixture>",
    markdown: "# 결정 사항\n\n- 다음 주 출시 검토\n- **담당자**: 제품 팀\n\n<script>alert('unsafe')</script>\n\n[unsafe](javascript:alert(1))",
  }), 200)).json();
  const firstURL = publicURL(created.url);
  const head = await checkStatus(await fetch(firstURL, { method: "HEAD" }), 200);
  assert.equal(await head.text(), "");
  assert.equal(head.headers.get("www-authenticate"), null);
  const malformed = await checkStatus(await fetch(`${firstURL}/`), 404);
  assert.equal(malformed.headers.get("www-authenticate"), null);
  assert.ok(created.expiresAt >= before + 7 * 86400000);
  assert.ok(created.expiresAt <= Date.now() + 7 * 86400000);
  const page = await checkStatus(await fetch(firstURL), 200);
  assert.match(page.headers.get("content-type"), /text\/html/);
  assert.match(page.headers.get("cache-control"), /no-store/);
  assert.match(page.headers.get("content-security-policy"), /default-src 'none'/);
  assert.match(page.headers.get("x-robots-tag"), /noindex/);
  assert.equal(page.headers.get("referrer-policy"), "no-referrer");
  const html = await page.text();
  assert.match(html, /결정 사항/);
  assert.ok(!html.includes("<script>"));
  assert.ok(!/href\s*=\s*["']javascript:/i.test(html));
  assert.ok(!html.includes(token));
  const state = await (await checkStatus(await admin("GET"), 200)).json();
  assert.equal(state.active, true);
  assert.equal(state.expiresAt, created.expiresAt);
  assert.equal(state.url, undefined);

  // An invalid publication must preserve the existing valid snapshot.
  await checkStatus(await admin("PUT", { title: "bad", markdown: "bad", transcript: "PRIVATE" }), 400);
  await checkStatus(await fetch(firstURL), 200);

  const replaced = await (await checkStatus(await admin("PUT", {
    title: "수정본", markdown: "## 새 결정\n\n수정한 회의록입니다.",
  }), 200)).json();
  const secondURL = publicURL(replaced.url);
  assert.notEqual(firstURL.href, secondURL.href);
  await checkStatus(await fetch(firstURL), 404);
  await checkStatus(await fetch(secondURL), 200);
  await checkStatus(await admin("DELETE"), 204);
  const revoked = await checkStatus(await fetch(secondURL), 404);
  assert.match(revoked.headers.get("cache-control"), /no-store/);
  assert.deepEqual(await (await checkStatus(await admin("GET"), 200)).json(), { active: false });
  await checkStatus(await admin("DELETE"), 204);
  console.log(`Web sharing HTTP lifecycle passed (${checks} status checks, HTML/security and snapshot assertions).`);
} finally {
  await admin("DELETE");
}
