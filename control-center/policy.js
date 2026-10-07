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
