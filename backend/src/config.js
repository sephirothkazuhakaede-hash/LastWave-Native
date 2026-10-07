import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const sourceDirectory = path.dirname(fileURLToPath(import.meta.url));
export const backendRoot = path.resolve(sourceDirectory, '..');

export function loadEnvironment(filePath = path.join(backendRoot, '.env')) {
  if (!fs.existsSync(filePath)) return;
  const text = fs.readFileSync(filePath, 'utf8');
  for (const rawLine of text.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const separator = line.indexOf('=');
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/u.test(key) || process.env[key] !== undefined) continue;
    let value = line.slice(separator + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

function booleanValue(name, fallback) {
  const value = process.env[name];
  if (value === undefined || value === '') return fallback;
  if (/^(1|true|yes|on)$/iu.test(value)) return true;
  if (/^(0|false|no|off)$/iu.test(value)) return false;
  throw new Error(`${name} must be true or false.`);
}

function integerValue(name, fallback, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const value = process.env[name];
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    throw new Error(`${name} must be an integer from ${min} through ${max}.`);
  }
  return parsed;
}

function resolveFromBackend(value) {
  return path.isAbsolute(value) ? value : path.resolve(backendRoot, value);
}

export function isLoopbackHost(host) {
  const normalized = String(host).trim().toLowerCase().replace(/^\[|\]$/gu, '');
  return normalized === 'localhost' || normalized === '127.0.0.1' || normalized === '::1';
}

export function loadConfig() {
  loadEnvironment();
  const host = process.env.BIND_HOST?.trim() || '127.0.0.1';
  const allowLan = booleanValue('ALLOW_LAN', false);
  const allowAnonymousLan = booleanValue('ALLOW_ANONYMOUS_LAN', false);
  const authMode = (process.env.AUTH_MODE?.trim() || 'local').toLowerCase();

  if (!['local', 'firebase'].includes(authMode)) {
    throw new Error('AUTH_MODE must be local or firebase.');
  }
  if (!isLoopbackHost(host) && !allowLan) {
    throw new Error('Refusing a non-loopback BIND_HOST unless ALLOW_LAN=true.');
  }
  if (!isLoopbackHost(host) && authMode === 'local' && !allowAnonymousLan) {
    throw new Error('LAN mode requires AUTH_MODE=firebase or the explicit ALLOW_ANONYMOUS_LAN=true opt-in.');
  }

  const firebaseProjectId = process.env.FIREBASE_PROJECT_ID?.trim() || '';
  if (authMode === 'firebase' && !firebaseProjectId) {
    throw new Error('FIREBASE_PROJECT_ID is required when AUTH_MODE=firebase.');
  }

  return Object.freeze({
    host,
    port: integerValue('PORT', 8787, { min: 1, max: 65_535 }),
    allowLan,
    allowAnonymousLan,
    authMode,
    firebaseProjectId,
    adminUIDs: (process.env.CAPYFLOW_ADMIN_UIDS || '').split(',').map(value => value.trim()).filter(Boolean),
    bannerDir: resolveFromBackend(process.env.BANNER_DIR?.trim() || './data/profile-banners'),
    pushEnabled: booleanValue("PUSH_NOTIFICATIONS", false),
    pushCredentials: process.env.PUSH_SERVICE_ACCOUNT?.trim() ? resolveFromBackend(process.env.PUSH_SERVICE_ACCOUNT.trim()) : null,
    pushStateFile: resolveFromBackend(process.env.PUSH_STATE_FILE?.trim() || "./state/message-push.json"),
    ytDlpPath: resolveFromBackend(process.env.YTDLP_PATH?.trim() || './bin/yt-dlp.exe'),
    cacheDir: resolveFromBackend(process.env.CACHE_DIR?.trim() || './cache'),
    cacheMaxBytes: integerValue('CACHE_MAX_BYTES', 10 * 1024 * 1024 * 1024, { min: 64 * 1024 * 1024 }),
    cacheMaxAgeMs: integerValue('CACHE_MAX_AGE_DAYS', 30, { min: 1, max: 3650 }) * 86_400_000,
    cacheConcurrency: integerValue('CACHE_CONCURRENCY', 2, { min: 1, max: 8 }),
    resolveTimeoutMs: integerValue('RESOLVE_TIMEOUT_MS', 45_000, { min: 5_000, max: 300_000 }),
    downloadTimeoutMs: integerValue('DOWNLOAD_TIMEOUT_MS', 900_000, { min: 30_000, max: 7_200_000 }),
    resolveCacheMs: integerValue('RESOLVE_CACHE_SECONDS', 900, { min: 30, max: 21_600 }) * 1000,
    diagnosticHistory: integerValue('DIAGNOSTIC_HISTORY', 100, { min: 10, max: 1000 }),
    corsOrigin: process.env.CORS_ORIGIN?.trim() || '',
  });
}
