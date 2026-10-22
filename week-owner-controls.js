const escape = (value = '') => String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const normalizedName = (name = '') => name.trim().replace(/\s+/g, ' ');
/** A guest's rendered portrait (Assets/Guest/<Name>, framed in the app's People & Photos). */
export function guestPhotoPath(name) {
  const value = normalizedName(name);
  return value && value.length <= 100 && !/[/\\?#%]|\.\./.test(value)
    ? `Images/People/${value}/portrait.webp` : '';
}
const imageUrl = (path, assetRoot) => `${assetRoot}${path.split('?')[0].split('/').map(encodeURIComponent).join('/')}`;

export function guestPhotoFields(week) {
  return `<fieldset class="guest-photo-editor" ${week.guest_judge_name ? '' : 'hidden'}>
    <legend>Guest judge photo</legend>
    <div class="guest-photo-preview-row"><span class="guest-photo-preview cast-avatar-frame"></span><p data-guest-photo-status role="status"></p></div>
    <p class="sub">Guests and their photos come from <b>Assets/Guest/&lt;Name&gt;</b>. Set the crop in the app under People &amp; Photos.</p>
  </fieldset>`;
}

export function bindGuestPhotoEditor(root, week, assetRoot = '') {
  const editor = root.querySelector('.guest-photo-editor');
  const nameInput = root.querySelector('#guestJudgeName');
  const enabled = root.querySelector('#guestJudgeEnabled');
  const status = editor.querySelector('[data-guest-photo-status]');
  const preview = editor.querySelector('.guest-photo-preview');
  let currentPath = null;
  function render() {
    const name = normalizedName(nameInput.value);
    editor.hidden = !enabled.checked;
    const path = enabled.checked ? guestPhotoPath(name).replace('/portrait.webp', '/profile.webp') : '';
    if (path === currentPath) return;
    currentPath = path; preview.replaceChildren();
    status.textContent = path ? name : 'Choose the guest judge.';
    if (!path) return;
    const img = document.createElement('img'); img.alt = `${name} headshot`;
    img.dataset.fallbackApplied = 'true';
    img.addEventListener('error', () => { if (currentPath === path) {
      img.hidden = true; status.textContent = `${name} has no photo yet. Add Assets/Guest/${name}/${name}.jpg and push.`;
    } });
    img.src = imageUrl(path, assetRoot); preview.append(img);
  }
  nameInput.addEventListener('input', render); nameInput.addEventListener('change', render);
  enabled.addEventListener('change', render);
  render();
  // The database sets the photo from the guest's name, so nothing extra is saved.
  return () => ({ p_guest_judge_image_path: null, p_guest_judge_avatar_frame: {} });
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
