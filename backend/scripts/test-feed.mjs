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
  const query = globalThis.feedQueries.at(-1);
  assert.match(query.text, /owner_user_id IS DISTINCT FROM/);
  assert.ok(query.values.includes(userId));
  assert.ok(query.text.indexOf('owner_user_id IS DISTINCT FROM') < query.text.indexOf('LIMIT'));
  assert.equal(response.headers.get('cache-control'), 'private, max-age=0, no-store');
}
const guest = await get('/v1/feed?limit=2');
assert.equal(guest.status, 200);
assert.equal((await guest.json()).viewerID, null);
assert.ok(!globalThis.feedQueries.at(-1).values.includes(userId));
const map = await get('/v1/map/clips?country=TH', 'Bearer ' + token);
assert.equal(map.status, 200);
assert.ok(!globalThis.feedQueries.at(-1).values.includes(userId), 'map must retain own clips');
assert.ok(globalThis.feedQueries.at(-1).values.includes('TH'));
const before = globalThis.feedQueries.length;
assert.equal((await get('/v1/feed', 'Bearer invalid-session')).status, 401);
assert.equal(globalThis.feedQueries.length, before, 'invalid auth must not query guest feed');
assert.equal((await get('/v1/feed?limit=0')).status, 400);
console.log('Feed route/auth/SQL checks passed (head, cursor, guest, map, invalid session).');
