const $ = id => document.getElementById(id);
const call = (action, value) => window.control.call(action, value);
let busy = false;
let activePage = 'banners', nextUserPage = '';
function clearPrivateViews() {
  for (const id of ['library', 'users-list', 'announcements-list', 'messages-list', 'audit-list']) $(id).replaceChildren();
  for (const id of ['user-query', 'announcement-id', 'announcement-title', 'announcement-body', 'push-title', 'push-body']) $(id).value = '';
  $('push-result').textContent = ''; $('push-audience').textContent = 'Sign in to load the audience.'; $('status').textContent = '';
  $('local-preview').hidden = true; $('local-preview').removeAttribute('src'); $('release-editor').hidden = true;
  $('connection').textContent = 'Not connected'; nextUserPage = ''; $('next-users').hidden = true;
}
function localSummary(status) {
  return `${status.healthy ? 'Backend online' : 'Backend offline'}\n${status.managed ? 'Running inside Control Center' : 'Existing external backend'}\nData folder: ${status.dataDirectory}\nPublic connection: ${status.publicURL || 'Existing tunnel / automatic discovery'}${status.publication ? '\n' + status.publication : ''}${status.exitError ? '\n' + status.exitError : ''}${status.note ? '\n' + status.note : ''}\n\nRecent server log\n${(status.logs || []).slice(-12).join('\n')}`;
}
function serverSummary(status) {
  return `Connected to CapyFlow\nUptime: ${Math.floor(status.uptimeSeconds / 60)} minutes\nAvailable banners: ${status.banners}\nCached music tracks: ${status.cache?.entries ?? 'Unavailable'}\nMusic resolver: ${status.ytDlpInstalled ? 'Ready' : 'Check setup'}\nNotifications: ${status.pushConfigured ? 'Configured' : 'Check setup'}\nAdmin tools: ${status.adminConfigured ? 'Configured' : 'Service-account setup required'}`;
}
async function run(operation) {
  if (busy) return; busy = true; $('message').textContent = '';
  try { await operation(); } catch (error) { if (/sign in first|sign-in expired|session expired/iu.test(error.message)) clearPrivateViews(); $('message').textContent = error.message; }
  finally { busy = false; }
}
async function refreshBanners() {
  const [catalog, status] = await Promise.all([call('list'), call('status')]);
  $('connection').textContent = 'Administrator connected'; $('library').replaceChildren();
  $('status').textContent = serverSummary(status);
  for (const banner of catalog.banners) {
    const card = document.createElement('article'), img = document.createElement('img'); img.alt = banner.name;
    img.src = await call('preview', banner); card.append(img);
    const name = document.createElement('input'); name.value = banner.name; name.maxLength = 60; name.setAttribute('aria-label', 'Banner name'); card.append(name);
    const detail = document.createElement('p'); detail.textContent = `${banner.id} · ${banner.published ? 'Published' : 'Draft'} · ${Math.round(banner.byteSize / 1024)} KB`; card.append(detail);
    const actions = document.createElement('div'); actions.className = 'actions';
    for (const [label, action] of [
      [banner.published ? 'Unpublish' : 'Publish', async () => call('update', { id: banner.id, patch: { published: !banner.published } })],
      ['Save name', async () => { if (name.value.trim()) await call('update', { id: banner.id, patch: { name: name.value.trim() } }); }],
      ['Delete', async () => { if (confirm(`Delete “${banner.name}” and its GIF file? Profiles will use their default appearance. This cannot be undone.`)) await call('delete', banner.id); }],
    ]) { const button = document.createElement('button'); button.textContent = label; button.onclick = () => run(async () => { await action(); await refresh(); }); actions.append(button); }
    card.append(actions); $('library').append(card);
  }
  if (!catalog.banners.length) $('library').textContent = 'Your library is empty. Upload a GIF to create the first draft.';
}
$('connect').onclick = () => run(async () => { clearPrivateViews(); await call('connect', $('backend').value); $('message').textContent = 'Complete Google sign-in in your browser, then return here.'; });
$('logout').onclick = () => run(async () => { await call('logout'); clearPrivateViews(); });
$('refresh').onclick = () => run(refresh);
$('pick').onclick = () => run(async () => { const selected = await call('pick'); if (selected) { $('local-preview').src = selected.preview; $('local-preview').hidden = false; $('preview-label').hidden = true; $('file-name').textContent = selected.fileName; } });
$('upload').onclick = () => run(async () => { await call('upload', { id: $('banner-id').value.trim(), name: $('name').value.trim() }); $('message').textContent = 'Draft uploaded. Preview it in the library, then publish when ready.'; $('local-preview').hidden = true; $('preview-label').hidden = false; $('file-name').textContent = 'Nothing selected'; await refresh(); });
const pages = { banners: 'Profile banners', users: 'Users', announcements: 'Announcements', moderation: 'Global Chat', push: 'Notifications', updates: 'App updates', status: 'Backend & status', audit: 'Admin history' };
for (const page of Object.keys(pages)) $(page + '-tab').onclick = () => {
  activePage = page;
  for (const name of Object.keys(pages)) { $(name === 'banners' ? 'banner-page' : name + '-page').hidden = name !== page; $(name + '-tab').classList.toggle('active', name === page); }
  $('title').textContent = pages[page]; run(refresh);
};
function record(container, heading, detail, actions = []) {
  const article = document.createElement('article'), title = document.createElement('h3'), text = document.createElement('p');
  title.textContent = heading; text.textContent = detail; article.append(title, text);
  const row = document.createElement('div'); row.className = 'actions';
  for (const [label, action] of actions) { const button = document.createElement('button'); button.textContent = label; button.onclick = () => run(action); row.append(button); }
  article.append(row); $(container).append(article);
}
async function loadUsers(page = '') {
  const result = await call('users', { query: $('user-query').value.trim(), page }); $('users-list').replaceChildren();
  nextUserPage = result.nextPageToken; $('next-users').hidden = !nextUserPage;
  for (const user of result.users) record('users-list', user.displayName || user.username || 'CapyFlow user', `${user.email}\n@${user.username || 'no profile'} · ${user.disabled ? 'Disabled' : 'Active'}\n${user.uid}\nLast sign-in: ${user.lastSignIn || 'Never'}`, [[user.disabled ? 'Enable account' : 'Disable account', async () => {
    if (!confirm(`${user.disabled ? 'Enable' : 'Disable'} this account? ${user.email || user.uid}\nIts messages, playlists and profile will be preserved.`)) return;
    const result = await call('set-user', { uid: user.uid, disabled: !user.disabled }); await loadUsers(); $('message').textContent = result.note;
  }]]);
  if (!result.users.length) $('users-list').textContent = 'No matching accounts.';
}
async function loadAnnouncements() {
  const result = await call('announcements'); $('announcements-list').replaceChildren();
  for (const item of result.announcements) record('announcements-list', item.title, `${item.published ? 'Published' : 'Draft'} · ${item.id}\n${item.body}`, [
    ['Edit', async () => { $('announcement-id').value = item.id; $('announcement-title').value = item.title; $('announcement-body').value = item.body; }],
    [item.published ? 'Withdraw' : 'Publish', async () => { if (!confirm(`${item.published ? 'Withdraw' : 'Publish'} “${item.title}” in Global Chat?`)) return; await call('save-announcement', { ...item, published: !item.published }); await loadAnnouncements(); }],
  ]);
}
async function saveAnnouncement(published) {
  if (published && !confirm('Publish this announcement to Global Chat for all signed-in listeners? Existing Android Global Chat push opt-ins will apply.')) return;
  await call('save-announcement', { id: $('announcement-id').value.trim(), title: $('announcement-title').value.trim(), body: $('announcement-body').value.trim(), published });
  await loadAnnouncements(); $('message').textContent = published ? 'Announcement published.' : 'Draft saved.';
}
async function loadMessages() {
  const result = await call('messages'); $('messages-list').replaceChildren();
  for (const item of result.messages) { const restore = item.text === '[Message removed by moderator]'; record('messages-list', `${item.senderID} · ${item.createdAt || ''}`, item.text, [[restore ? 'Restore message' : 'Hide message', async () => { if (!confirm(`${restore ? 'Restore' : 'Hide'} this Global Chat message?\n${item.text.slice(0,200)}`)) return; await call('moderate', { id: item.id, restore }); await loadMessages(); }]]); }
}
async function refresh() {
  if (activePage === 'banners') return refreshBanners();
  if (activePage === 'users') return loadUsers();
  if (activePage === 'announcements') return loadAnnouncements();
  if (activePage === 'moderation') return loadMessages();
  if (activePage === 'push') { const audience = await call('push-preview'); $('push-audience').textContent = `${audience.androidDevices} registered Android devices opted into Global Chat notifications.`; return; }
  if (activePage === 'updates') { const releases = await call('releases'); $('releases-list').replaceChildren(); for (const release of releases) record('releases-list', release.name || release.tag, `${release.prerelease ? 'Preview' : 'Stable'} · ${release.tag} · ${release.publishedAt}\n${release.notes}`, /^android-dev[0-9]+$/u.test(release.tag) ? [['Edit release notes', async () => { $('release-editor').hidden = false; $('release-tag').value = release.tag; $('release-notes').value = release.notes; }]] : []); return; }
  if (activePage === 'status') {
    $('local-status').textContent = localSummary(await call('local-status'));
    try { $('status').textContent = serverSummary(await call('status')); } catch (error) { $('status').textContent = error.message; } return;
  }
  if (activePage === 'audit') { const result = await call('audit'); $('audit-list').replaceChildren(); for (const event of result.events) record('audit-list', event.action, `${event.target}\n${event.createdAt}\nAdministrator: ${event.actor}`); }
}
$('find-users').onclick = () => run(() => loadUsers());
$('list-users').onclick = () => run(async () => { $('user-query').value = ''; await loadUsers(); });
$('next-users').onclick = () => run(() => loadUsers(nextUserPage));
$('announcement-draft').onclick = () => run(() => saveAnnouncement(false));
$('announcement-publish').onclick = () => run(() => saveAnnouncement(true));
$('send-push').onclick = () => run(async () => {
  const audience = await call('push-preview');
  if (!confirm(`Send this notification to up to ${audience.androidDevices} opted-in Android devices?\n${$('push-title').value}\n${$('push-body').value}\nSent notifications cannot be recalled.`)) return;
  const result = await call('send-push', { title: $('push-title').value.trim(), body: $('push-body').value.trim() });
  $('push-result').textContent = `Accepted by Firebase: ${result.success}\nFailed: ${result.failed}\nAcceptance does not guarantee the phone displayed it.`;
});
for (const action of ['local-start', 'local-stop', 'local-restart', 'local-folder']) $(action).onclick = () => run(async () => {
  if (['local-stop', 'local-restart'].includes(action) && !confirm('This briefly interrupts music and remote banner access. Continue when downloads have finished?')) return;
  const result = await call(action); if (result) $('local-status').textContent = localSummary(result);
});
$('publish-android').onclick = () => run(async () => {
  if (!confirm(`Publish Android ${$('new-version').value} (build ${$('new-build').value}) for everyone after its checks pass?\nThis creates a version/release-notes commit on the Android branch and starts a stable build.`)) return;
  $('message').textContent = (await call('publish-android', { versionName: $('new-version').value, versionCode: $('new-build').value, notes: $('new-release-notes').value })).note;
});
$('save-release-notes').onclick = () => run(async () => { if (!confirm(`Update the published notes for ${$('release-tag').value}? The APK and its checksum will stay the same.`)) return; const result = await call('release-notes', { tag: $('release-tag').value, notes: $('release-notes').value }); await refresh(); $('message').textContent = result.note; });
window.control.onConnected(() => run(refresh));
const settings = await call('settings'); $('backend').value = settings.backend;
if (settings.connected) await run(refresh);
