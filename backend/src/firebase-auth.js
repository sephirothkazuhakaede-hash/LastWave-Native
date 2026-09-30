import crypto from 'node:crypto';
import { HttpError } from './errors.js';

const certificateUrl = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';

function decodePart(value, label) {
  try {
    return JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
  } catch {
    throw new HttpError(401, 'invalid_token', `The Firebase token ${label} is invalid.`);
  }
}

function maxAgeMilliseconds(response) {
  const cacheControl = response.headers.get('cache-control') || '';
  const match = /(?:^|,)\s*max-age=(\d+)/iu.exec(cacheControl);
  return match ? Math.max(60_000, Number(match[1]) * 1000) : 3_600_000;
}

export class FirebaseTokenVerifier {
  #projectId;
  #fetch;
  #clock;
  #certificates = null;
  #certificatesExpireAt = 0;
  #certificatesJob = null;

  constructor({ projectId, fetchImpl = globalThis.fetch, clock = () => Date.now() }) {
    this.#projectId = projectId;
    this.#fetch = fetchImpl;
    this.#clock = clock;
  }

  async verify(token) {
    const parts = String(token).split('.');
    if (parts.length !== 3) throw new HttpError(401, 'invalid_token', 'The Firebase token is malformed.');
    const header = decodePart(parts[0], 'header');
    const claims = decodePart(parts[1], 'payload');
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' || !header.kid) {
      throw new HttpError(401, 'invalid_token', 'The Firebase token algorithm or key is invalid.');
    }

    let certificates = await this.#getCertificates();
    let certificate = certificates[header.kid];
    if (!certificate) {
      this.#certificatesExpireAt = 0;
      certificates = await this.#getCertificates();
      certificate = certificates[header.kid];
    }
    if (!certificate) throw new HttpError(401, 'invalid_token', 'The Firebase token signing key is unknown.');

    const signed = Buffer.from(`${parts[0]}.${parts[1]}`);
    const signature = Buffer.from(parts[2], 'base64url');
    const validSignature = crypto.verify('RSA-SHA256', signed, certificate, signature);
    if (!validSignature) throw new HttpError(401, 'invalid_token', 'The Firebase token signature is invalid.');

    const now = Math.floor(this.#clock() / 1000);
    const skew = 300;
    const expectedIssuer = `https://securetoken.google.com/${this.#projectId}`;
    const validAudience = claims.aud === this.#projectId ||
      (Array.isArray(claims.aud) && claims.aud.includes(this.#projectId));
    if (claims.iss !== expectedIssuer || !validAudience) {
      throw new HttpError(401, 'invalid_token', 'The Firebase token belongs to another project.');
    }
    if (typeof claims.sub !== 'string' || !claims.sub || claims.sub.length > 128) {
      throw new HttpError(401, 'invalid_token', 'The Firebase token subject is invalid.');
    }
    if (!Number.isFinite(claims.exp) || claims.exp <= now - skew) {
      throw new HttpError(401, 'expired_token', 'The Firebase token has expired.');
    }
    if (!Number.isFinite(claims.iat) || claims.iat > now + skew) {
      throw new HttpError(401, 'invalid_token', 'The Firebase token issue time is invalid.');
    }
    if (claims.auth_time !== undefined && (!Number.isFinite(claims.auth_time) || claims.auth_time > now + skew)) {
      throw new HttpError(401, 'invalid_token', 'The Firebase authentication time is invalid.');
    }
    return claims;
  }

  async #getCertificates() {
    if (this.#certificates && this.#certificatesExpireAt > this.#clock()) return this.#certificates;
    if (this.#certificatesJob) return this.#certificatesJob;
    this.#certificatesJob = (async () => {
      let response;
      try {
        response = await this.#fetch(certificateUrl, {
          headers: { 'user-agent': 'CapyFlow-Media-Backend' },
          signal: AbortSignal.timeout(10_000),
        });
      } catch (error) {
        throw new HttpError(503, 'auth_keys_unavailable', 'Firebase signing keys are temporarily unavailable.', { cause: error });
      }
      if (!response.ok) {
        throw new HttpError(503, 'auth_keys_unavailable', 'Firebase signing keys are temporarily unavailable.');
      }
      const certificates = await response.json();
      if (!certificates || typeof certificates !== 'object' || Array.isArray(certificates)) {
        throw new HttpError(503, 'auth_keys_unavailable', 'Firebase returned an invalid signing-key response.');
      }
      this.#certificates = certificates;
      this.#certificatesExpireAt = this.#clock() + maxAgeMilliseconds(response);
      return certificates;
    })();
    try {
      return await this.#certificatesJob;
    } finally {
      this.#certificatesJob = null;
    }
  }
}

export function isLoopbackAddress(address) {
  const normalized = String(address || '').toLowerCase();
  return normalized === '127.0.0.1' || normalized === '::1' || normalized === '::ffff:127.0.0.1';
}

export async function authorizeRequest(request, config, verifier) {
  if (config.authMode === 'local') {
    if (isLoopbackAddress(request.socket.remoteAddress) || config.allowAnonymousLan) {
      return { uid: null, mode: isLoopbackAddress(request.socket.remoteAddress) ? 'loopback' : 'anonymous-lan' };
    }
    throw new HttpError(403, 'lan_auth_required', 'Anonymous LAN access is disabled.');
  }

  const authorization = request.headers.authorization || '';
  const match = /^Bearer\s+([^\s]+)$/iu.exec(authorization);
  if (!match) throw new HttpError(401, 'missing_token', 'A Firebase ID token is required.');
  const claims = await verifier.verify(match[1]);
  return { uid: claims.sub, mode: 'firebase' };
}
