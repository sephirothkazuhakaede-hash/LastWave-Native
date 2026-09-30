import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import test from 'node:test';
import { FirebaseTokenVerifier } from '../src/firebase-auth.js';

function tokenFor(privateKey, claims, kid = 'test-key') {
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid })).toString('base64url');
  const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
  const data = `${header}.${payload}`;
  const signature = crypto.sign('RSA-SHA256', Buffer.from(data), privateKey).toString('base64url');
  return `${data}.${signature}`;
}

test('FirebaseTokenVerifier validates signature, issuer, audience, and expiry', async () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const projectId = 'capyflow-test';
  const nowMs = Date.UTC(2026, 0, 1);
  const now = Math.floor(nowMs / 1000);
  let certificateFetches = 0;
  const fetchImpl = async () => {
    certificateFetches += 1;
    return new Response(JSON.stringify({
      'test-key': publicKey.export({ type: 'spki', format: 'pem' }),
    }), { status: 200, headers: { 'cache-control': 'public, max-age=3600' } });
  };
  const verifier = new FirebaseTokenVerifier({ projectId, fetchImpl, clock: () => nowMs });
  const token = tokenFor(privateKey, {
    iss: `https://securetoken.google.com/${projectId}`,
    aud: projectId,
    sub: 'firebase-user-1',
    iat: now - 60,
    auth_time: now - 120,
    exp: now + 3600,
  });
  const claims = await verifier.verify(token);
  assert.equal(claims.sub, 'firebase-user-1');
  assert.equal(certificateFetches, 1);
  await verifier.verify(token);
  assert.equal(certificateFetches, 1, 'certificate response should be cached');

  const wrongAudience = tokenFor(privateKey, {
    iss: `https://securetoken.google.com/${projectId}`,
    aud: 'another-project', sub: 'firebase-user-1', iat: now, exp: now + 3600,
  });
  await assert.rejects(verifier.verify(wrongAudience), /another project/u);
});
