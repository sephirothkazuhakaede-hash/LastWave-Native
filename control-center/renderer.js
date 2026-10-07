const $ = id => document.getElementById(id);
const call = (action, value) => window.control.call(action, value);
let busy = false;
async function run(operation) {
  if (busy) return; busy = true; $('message').textContent = '';
  try { await operation(); } catch (error) { $('message').textContent = error.message; }
  finally { busy = false; }
}
async function refresh() {
  const [catalog, status] = await Promise.all([call('list'), call('status')]);
  $('connection').textContent = 'Administrator connected'; $('library').replaceChildren();
  $('status').textContent = JSON.stringify(status, null, 2);
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
$('connect').onclick = () => run(async () => { await call('connect', $('backend').value); $('message').textContent = 'Complete Google sign-in in your browser, then return here.'; });
$('logout').onclick = () => run(async () => { await call('logout'); $('connection').textContent = 'Not connected'; $('library').replaceChildren(); $('status').textContent = ''; });
$('refresh').onclick = () => run(refresh);
$('pick').onclick = () => run(async () => { const selected = await call('pick'); if (selected) { $('local-preview').src = selected.preview; $('local-preview').hidden = false; $('preview-label').hidden = true; $('file-name').textContent = selected.fileName; } });
$('upload').onclick = () => run(async () => { await call('upload', { id: $('banner-id').value.trim(), name: $('name').value.trim() }); $('message').textContent = 'Draft uploaded. Preview it in the library, then publish when ready.'; $('local-preview').hidden = true; $('preview-label').hidden = false; $('file-name').textContent = 'Nothing selected'; await refresh(); });
for (const page of ['banners', 'status']) $(page + '-tab').onclick = () => { $('banner-page').hidden = page !== 'banners'; $('status-page').hidden = page !== 'status'; $('title').textContent = page === 'banners' ? 'Profile banners' : 'Server status'; $('banners-tab').classList.toggle('active', page === 'banners'); $('status-tab').classList.toggle('active', page === 'status'); };
window.control.onConnected(() => run(refresh));
const settings = await call('settings'); $('backend').value = settings.backend;
if (settings.connected) await run(refresh);
