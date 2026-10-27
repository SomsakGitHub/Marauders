import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { SignJWT } from 'jose';
import { webcrypto } from 'node:crypto';
globalThis.crypto ??= webcrypto;

// Execute the real router, auth verifier and SQL builder without production DB access.
globalThis.feedQueries = [];
const result = await build({
  entryPoints: ['src/index.ts'], absWorkingDir: new URL('..', import.meta.url).pathname,
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'database-spy', setup(build) {
    build.onResolve({ filter: /^@neondatabase\/serverless$/ }, () => ({ path: 'neon', namespace: 'spy' }));
    build.onLoad({ filter: /.*/, namespace: 'spy' }, () => ({ contents:
      'export function neon() { return async (strings, ...values) => { globalThis.feedQueries.push({text: strings.join("?"), values}); return []; }; }', loader: 'js' }));
  }}],
});
const { default: worker } = await import('data:text/javascript;base64,' + Buffer.from(result.outputFiles[0].text).toString('base64'));
const secret = 'feed-test-secret-with-at-least-32-characters';
const userId = '12345678-1234-4234-8234-123456789abc';
const token = await new SignJWT({}).setProtectedHeader({alg:'HS256'}).setSubject(userId)
  .setExpirationTime('1h').sign(new TextEncoder().encode(secret));
const env = { DATABASE_URL: 'test-only', JWT_SIGNING_SECRET: secret };
async function get(path, auth) {
  const headers = auth ? { Authorization: auth } : {};
  return worker.fetch(new Request('https://test.invalid' + path, {headers}), env);
}
for (const cursor of ['', '&cursor=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee']) {
  const response = await get('/v1/feed?limit=2' + cursor, 'Bearer ' + token);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).viewerID, userId);
  // The viewer's own clips are part of the feed: nothing filters on the owner, and the viewer is not a query parameter.
  const query = globalThis.feedQueries.at(-1);
  assert.doesNotMatch(query.text, /owner_user_id\s+(IS DISTINCT FROM|<>|!=)/);
  assert.doesNotMatch(query.text, /WHERE[^]*owner_user_id\s*=/);
  assert.ok(!query.values.includes(userId), 'the feed must not leave out the viewer\'s own clips');
  assert.match(query.text, /FROM feed_videos v/);
  assert.match(query.text, /ORDER BY v\.sort_order DESC, v\.created_at DESC, v\.id DESC/);
  assert.equal(response.headers.get('cache-control'), 'private, max-age=0, no-store');
}
const guest = await get('/v1/feed?limit=2');
assert.equal(guest.status, 200);
assert.equal((await guest.json()).viewerID, null);
assert.ok(!globalThis.feedQueries.at(-1).values.includes(userId));
// A signed-in and a guest feed ask the database the same question.
const withSession = await get('/v1/feed?limit=2&country=TH', 'Bearer ' + token);
const asGuest = await get('/v1/feed?limit=2&country=TH');
assert.equal(withSession.status, 200);
assert.equal(asGuest.status, 200);
const [signedInQuery, guestQuery] = globalThis.feedQueries.slice(-2);
assert.equal(signedInQuery.text, guestQuery.text);
assert.deepEqual(signedInQuery.values, guestQuery.values);
const map = await get('/v1/map/clips?limit=2&country=TH', 'Bearer ' + token);
assert.equal(map.status, 200);
// The map reads exactly what the feed reads.
const mapQuery = globalThis.feedQueries.at(-1);
assert.equal(mapQuery.text, signedInQuery.text);
assert.deepEqual(mapQuery.values, signedInQuery.values);
assert.ok(mapQuery.values.includes('TH'));
for (const response of [withSession, asGuest, map]) {
  assert.equal(response.headers.get('cache-control'), 'private, max-age=0, no-store');
}
const before = globalThis.feedQueries.length;
// A session that is supplied but not valid is an error, not a guest feed. The long ones get as far as the signature check.
const otherKey = new TextEncoder().encode('another-secret-with-at-least-32-characters-x');
const wrongSecret = await new SignJWT({}).setProtectedHeader({alg:'HS256'}).setSubject(userId).setExpirationTime('1h').sign(otherKey);
const expired = await new SignJWT({}).setProtectedHeader({alg:'HS256'}).setSubject(userId)
  .setIssuedAt(Math.floor(Date.now() / 1000) - 7200).setExpirationTime(Math.floor(Date.now() / 1000) - 3600).sign(new TextEncoder().encode(secret));
for (const bad of ['Bearer invalid-session', 'Bearer ' + 'x'.repeat(40), 'Bearer ' + wrongSecret, 'Bearer ' + expired]) {
  for (const path of ['/v1/feed', '/v1/map/clips']) {
    const refused = await get(path, bad);
    assert.equal(refused.status, 401, path + ' ' + bad.slice(0, 20));
    assert.equal(refused.headers.get('cache-control'), 'private, max-age=0, no-store');
  }
}
assert.equal(globalThis.feedQueries.length, before, 'invalid auth must not query guest feed');
assert.equal((await get('/v1/feed?limit=0')).status, 400);
console.log('Feed route/auth/SQL checks passed (head, cursor, own clips kept, guest, map, invalid session).');
