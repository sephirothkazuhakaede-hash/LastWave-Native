export function backendRoot(raw) {
  const url = new URL(raw.trim());
  if (url.username || url.password || url.search || url.hash ||
      !(url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)))) {
    throw new Error('Use an HTTPS server address, or localhost for development.');
  }
  return url.href.replace(/\/$/u, '').replace(/\/v1$/u, '');
}
export function bannerID(raw) {
  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/u.test(raw) || raw === 'none') throw new Error('Use 1–64 lowercase letters, numbers, underscores or dashes for the ID.');
  return raw;
}
export function releaseInput(value) {
  const versionName = String(value?.versionName || '').trim(), versionCode = Number(value?.versionCode), notes = String(value?.notes || '').trim();
  if (!/^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$/u.test(versionName)) throw Error('Use a version such as 1.0.10.');
  if (!Number.isSafeInteger(versionCode) || versionCode < 1 || versionCode > 2100000000) throw Error('Use a valid positive Android build number.');
  if (!notes || notes.length > 6000) throw Error('Add release notes of up to 6,000 characters.');
  return { versionName, versionCode, notes };
}
