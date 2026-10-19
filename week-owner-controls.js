import { avatarFrameFor, avatarImageStyle } from './cast-avatar-frame.js?v=20261019-app-parity-v115';

const escape = (value = '') => String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const normalizedName = (name = '') => name.trim().replace(/\s+/g, ' ');
export function guestPhotoPath(name) {
  const value = normalizedName(name);
  return value && value.length <= 100 && !/[/\\?#%]|\.\./.test(value)
    ? `Images/Guests/${value}.jpeg` : '';
}
const imageUrl = (path, assetRoot) => `${assetRoot}${path.split('/').map(encodeURIComponent).join('/')}?v=20261014-guests`;
const frame = (value) => avatarFrameFor({ profile_details: { _avatar_frame: value } });

export function guestPhotoFields(week) {
  const crop = frame(week.guest_judge_avatar_frame);
  return `<fieldset class="guest-photo-editor" ${week.guest_judge_name ? '' : 'hidden'}>
    <legend>Guest judge photo</legend>
    <label>Photo<select data-guest-photo-choice><option value="">Automatic · match guest name</option></select></label>
    <p class="sub">Upload <b>First Last.jpeg</b> to <b>Images/Guests</b>. Names and capitalization must match. No cast member is needed.</p>
    <div class="guest-photo-preview-row"><span class="guest-photo-preview"></span><p data-guest-photo-status role="status"></p></div>
    ${[['x','Horizontal position',0,100,1],['y','Vertical position',0,100,1],['zoom','Zoom',1,3,0.05]].map(([key,label,min,max,step]) =>
      `<label>${label}<input data-guest-crop="${key}" type="range" min="${min}" max="${max}" step="${step}" value="${crop[key]}"></label>`).join('')}
    <button type="button" class="secondary" data-guest-reset>Reset framing</button>
  </fieldset>`;
}

export function bindGuestPhotoEditor(root, week, assetRoot = '') {
  const editor = root.querySelector('.guest-photo-editor');
  const nameInput = root.querySelector('#guestJudgeName');
  const enabled = root.querySelector('#guestJudgeEnabled');
  const choice = editor.querySelector('[data-guest-photo-choice]');
  const status = editor.querySelector('[data-guest-photo-status]');
  const preview = editor.querySelector('.guest-photo-preview');
  let currentName = normalizedName(nameInput.value);
  let currentPath = null;
  let photoExists = false;
  const savedPath = week.guest_judge_image_path;
  if (savedPath && savedPath !== guestPhotoPath(currentName)) {
    choice.add(new Option(savedPath.split('/').at(-1), savedPath, true, true));
  }
  const read = () => ({
    p_guest_judge_image_path: enabled.checked ? choice.value || null : null,
    p_guest_judge_avatar_frame: enabled.checked ? Object.fromEntries([...editor.querySelectorAll('[data-guest-crop]')]
      .map((input) => [input.dataset.guestCrop, Number(input.value)])) : {},
  });
  const reset = () => editor.querySelectorAll('[data-guest-crop]').forEach((input) => {
    input.value = input.dataset.guestCrop === 'zoom' ? 1 : 50;
  });
  function render() {
    const name = normalizedName(nameInput.value);
    if (name !== currentName) { currentName = name; choice.value = ''; reset(); }
    editor.hidden = !enabled.checked;
    const path = enabled.checked ? choice.value || guestPhotoPath(name) : '';
    if (path !== currentPath) {
      currentPath = path; photoExists = false; preview.replaceChildren();
      status.textContent = path ? `Loading ${path}…` : 'Enter the guest’s full name to preview their photo.';
      if (path) {
        const img = document.createElement('img'); img.alt = `${name} headshot preview`;
        // The app’s global image fallback must not conceal missing guest uploads.
        img.dataset.fallbackApplied = 'true';
        img.addEventListener('load', () => { if (currentPath === path) { photoExists = true; status.textContent = path; } });
        img.addEventListener('error', () => { if (currentPath === path) {
          img.hidden = true; status.textContent = `Photo not found yet: ${path}. Check the filename and publish the upload.`;
        } });
        img.src = imageUrl(path,assetRoot); preview.append(img);
      }
    }
    const img = preview.querySelector('img');
    if (img) img.style.cssText = avatarImageStyle({ profile_details: { _avatar_frame: read().p_guest_judge_avatar_frame } });
    if (photoExists) status.textContent = path;
  }
  nameInput.addEventListener('input',render); enabled.addEventListener('change',render);
  choice.addEventListener('change',render);
  editor.querySelectorAll('[data-guest-crop]').forEach((input) => input.addEventListener('input',render));
  editor.querySelector('[data-guest-reset]').addEventListener('click',() => { reset(); render(); });
  render();
  fetch(`${assetRoot}cast-thumbnail-manifest.json`, { cache:'no-cache' }).then((response) => response.ok ? response.json() : null)
    .then((manifest) => {
      if (!root.isConnected) return;
      for (const entry of manifest?.entries || []) {
        if (!entry.source.startsWith('Images/Guests/') || [...choice.options].some((o) => o.value===entry.source)) continue;
        choice.add(new Option(entry.source.split('/').at(-1),entry.source));
      }
    }).catch(() => {}); // Automatic filename lookup still works without the manifest.
  return read;
}

const time = (value) => value ? new Date(value).toLocaleString('en-US', {
  timeZone:'America/New_York',month:'short',day:'numeric',hour:'numeric',minute:'2-digit',
}) + ' ET' : 'Not yet';
export function predictionStatusMarkup(data) {
  if (!data) return '<p>Prediction status unavailable.</p><button type="button" class="secondary" data-check-predictions>Check status</button>';
  const stale = data.last_quote_at && Date.now()-Date.parse(data.last_quote_at)>35*60*1000;
  return `<h3>Elimination predictions</h3><p><b>${escape(data.event_ticker || 'Set an air date')}</b></p>
    <p>${data.enabled ? 'Enabled' : 'Disabled'} · ${Number(data.quote_count)||0} couples with prices${stale ? ' · Prices are stale' : ''}</p>
    <p class="sub">Last prices: ${time(data.last_quote_at)}. Last successful sync: ${time(data.last_sync_at)}.</p>
    ${data.error ? `<p class="automation-error">${escape(data.error)}</p>` : ''}
    ${data.pending ? '<p role="status">Refresh in progress…</p>' : ''}
    ${data.can_refresh && !data.quote_count && !data.pending && !data.error ? '<p class="sub">No prices imported yet. The market may not be open or matched yet.</p>' : ''}
    <div class="week-owner-actions"><button type="button" class="secondary" data-request-predictions ${!data.can_refresh || data.pending ? 'disabled' : ''}>Refresh now</button>
      <button type="button" class="secondary" data-check-predictions>Check status</button></div>
    <p class="sub">Enabling predictions requests an immediate refresh. Normal refreshes run every 15 minutes, or every 5 minutes during airing. Refresh now is available for the next enabled week.</p>`;
}

export function bindPredictionStatus(container, db, weekId) {
  let checking = false;
  const load = async () => {
    if (!container.isConnected || checking) return;
    checking = true;
    try {
      const {data,error} = await db.rpc('get_week_prediction_status',{p_week_id:weekId});
      if (container.isConnected) container.innerHTML = predictionStatusMarkup(error ? null : data);
    } finally { checking = false; }
  };
  container.addEventListener('click',async (event) => {
    const button=event.target.closest('button'); if (!button) return;
    if (button.hasAttribute('data-check-predictions')) return load();
    if (!button.hasAttribute('data-request-predictions')) return;
    button.disabled=true;
    const {data,error}=await db.rpc('request_week_prediction_refresh',{p_week_id:weekId});
    if (!container.isConnected) return;
    await load();
    const notice=document.createElement('p'); notice.setAttribute('role','status');
    notice.textContent=error ? error.message : data?.message || 'Refresh requested.';
    container.append(notice);
    if (!error) for (const delay of [3000,8000,15000]) setTimeout(load,delay);
  });
  load();
}
