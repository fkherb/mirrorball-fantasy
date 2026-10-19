import { db } from './supabase-client.js?v=20261019-app-parity-v115';
import { homeSections, normalizeHomeLayout, weekRecap, teamStanding, latestResultsWeek } from './home-model.js?v=20261019-app-parity-v115';
import { configureSpoilers, observeResults, hiddenResultsWeek, setHiddenResults, spoilerWarningsEnabled, setSpoilerWarnings } from './spoiler-settings.js?v=20261019-app-parity-v115';
import { activePartnershipPredictionRows, weeklyPredictionFor, isActivePrediction, predictionPercent, easternDateTime, airingWindows } from './market-prediction-model.js?v=20261019-app-parity-v115';
import { danceCardPhotoFor, couplePhotoFor } from './dance-images.js?v=20261019-app-parity-v115';
import { danceSongList } from './dance-song.js?v=20261019-app-parity-v115';
import { splitDanceType } from './dance-type.js?v=20261019-app-parity-v115';

const $ = (selector) => document.querySelector(selector);
const html = (value = '') => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
let account = {};
let current = null;
let invitations = [];
let homeLayout = normalizeHomeLayout();
let generation = 0;
let config = {};
let styles = [];
let configured = false;
const summaries = new Map();
const enabled = (feature) => config[`feature.${feature}`] !== false;
const storage = {
  read(key, fallback) { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } },
  write(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* Optional device preferences. */ } },
};
const layoutKey = () => `mirrorball-home-layout:${account.userId || 'guest'}`;

function sheet(title, content) {
  const panel = $('#experienceSheet');
  panel.innerHTML = `<div class="experience-sheet-head"><h2>${html(title)}</h2><button type="button" data-close-sheet aria-label="Close">×</button></div>${content}`;
  panel.querySelector('[data-close-sheet]').onclick = () => panel.close();
  if (!panel.open) panel.showModal();
}

export function initializeAppExperience() {
  if (!$('#memberOverview') || configured) return;
  configured = true;
  document.body.classList.add('app-experience');
  const sheetElement = document.createElement('dialog');
  sheetElement.id = 'experienceSheet';
  sheetElement.className = 'experience-sheet';
  document.body.append(sheetElement);
  sheetElement.addEventListener('click', (event) => { if (event.target === sheetElement && event.clientX < sheetElement.getBoundingClientRect().left) sheetElement.close(); });
  const nav = $('#primaryNav');
  const leaguesNav = $('#myLeaguesNav');
  leaguesNav.querySelector('.nav-label').textContent = 'Leagues';
  leaguesNav.title = 'Leagues';
  leaguesNav.setAttribute('aria-label', 'Leagues');
  leaguesNav.querySelector('.nav-icon').innerHTML = '<svg viewBox="0 0 24 24"><path d="M8 3h8v7a4 4 0 0 1-8 0zM8 5H4v3a5 5 0 0 0 5 5m7-8h4v3a5 5 0 0 1-5 5M12 14v6m-4 0h8"/></svg>';
  nav.querySelector('[data-view="score"]').after(leaguesNav);
  const directory = document.createElement('section');
  directory.id = 'leagues'; directory.className = 'view';
  directory.innerHTML = '<div class="splithead"><div><p class="eyebrow">Your season, together</p><h1>Leagues</h1><p class="sub">All your leagues, teams, and standings in one place.</p></div><div class="home-actions"><button data-create-league>Create a league</button><button class="secondary" data-join-league>Join with a code</button></div></div><div id="appLeagueDirectory" class="home-team-grid"></div><div id="directoryInvitations"></div>';
  $('main').append(directory);
  directory.querySelector('[data-create-league]').onclick = () => $('#createLeagueButton')?.click();
  directory.querySelector('[data-join-league]').onclick = () => $('#enterLeagueInviteCode')?.click();
  const standingsHeading = document.createElement('div');
  standingsHeading.className = 'app-league-standings';
  standingsHeading.innerHTML = '<div class="section-heading"><div><p class="eyebrow">Selected league</p><h2>Standings</h2></div><a href="#leagues">All leagues</a></div>';
  const overview = $('#memberOverview .overview-layout');
  standingsHeading.append(overview);
  $('#league .league-at-a-glance').before(standingsHeading);
  const feed = document.createElement('div'); feed.id = 'appHomeFeed';
  $('#memberOverview .standings-head').after(feed);
  for (const [id] of homeSections) {
    const section = document.createElement('section');
    section.dataset.homeSection = id;
    section.className = `home-section home-section-${id}`;
    if (id === 'showNight') section.innerHTML = '<div id="episodeSpotlight"></div>';
    feed.append(section);
  }
  $('#memberOverview .highlight-preview').hidden = true;
  $('#memberOverview').insertAdjacentHTML('beforeend', '<div class="home-footer"><button type="button" class="secondary" id="customizeHome">Customize Home</button><button type="button" class="text-action" id="learnMirrorball">Learn to play</button></div>');
  $('#customizeHome').onclick = customizeHome;
  $('#learnMirrorball').onclick = () => tutorial();
  $('#memberOverview .standings-head').insertAdjacentHTML('beforeend', '<div class="home-actions"><button class="secondary" id="homeNotifications" aria-label="Notifications">Notifications</button><button class="secondary" id="homeResults">Hide results</button></div>');
  $('#homeResults').onclick = () => {
    if (hiddenResultsWeek()) setHiddenResults(null);
    else if (current) setHiddenResults(latestResultsWeek(current.data)?.id || null);
  };
  $('#homeNotifications').onclick = notifications;
  $('#accountMenu .account-admin-links').before(Object.assign(document.createElement('div'), { className: 'account-web-settings', innerHTML: '<button type="button" id="websitePreferences" class="account-menu-link">Appearance & spoiler warnings</button><button type="button" id="accountLearn" class="account-menu-link">Learn to play</button><a class="account-menu-link" href="mailto:mirrorball-fantasy@codys-server.net">Help & feedback</a><a class="account-menu-link" href="privacy/">Privacy policy</a>' }));
  $('#websitePreferences').onclick = preferences;
  $('#accountLearn').onclick = () => tutorial();
  applyPalette(storage.read('mirrorball-web-palette', 'amethyst'));
  window.addEventListener('mirrorball-auth-change', (event) => {
    const next = event.detail;
    if (next.userId !== account.userId) { current = null; summaries.clear(); invitations = []; generation++; }
    account = next;
    configureSpoilers(account.userId);
    homeLayout = normalizeHomeLayout(storage.read(layoutKey(), {}));
    renderDirectory();
    if (!account.signedIn) {
      for (const section of feed.children) if (section.dataset.homeSection !== 'showNight') section.replaceChildren();
    }
    $('#customizeHome').hidden = !enabled('home_customize');
  });
  window.addEventListener('mirrorball-invitations', (event) => { invitations = event.detail || []; renderInvitations(); });
  window.addEventListener('mirrorball-spoilers-change', () => {
    if (current) renderHome();
    // Existing league renderers use the same spoiler state and keep actions/rules on raw data.
    window.dispatchEvent(new Event('mirrorball-refresh-presentation'));
  });
  window.addEventListener('mirrorball-dance-images', () => { if (current) renderHome(); });
  document.addEventListener('click', (event) => {
    if (event.target.closest('[data-reveal-results]')) setHiddenResults(null);
  });
  void loadCatalogs();
}

async function loadCatalogs() {
  const [settings, catalog] = await Promise.all([
    db.from('app_config').select('key,value').like('key', 'feature.%'),
    db.from('dance_styles').select('name,type,description').order('name'),
  ]);
  if (!settings.error) config = Object.fromEntries((settings.data || []).map((row) => [row.key, row.value]));
  if (!catalog.error) styles = catalog.data || [];
  if ($('#customizeHome')) $('#customizeHome').hidden = !enabled('home_customize');
}

export function updateAppExperience({ context, data, totals, weekTotals, openDance, openCast }) {
  if (!configured) return;
  account = { ...account, ...context };
  current = { data, totals, weekTotals, openDance, openCast };
  observeResults(data);
  summaries.set(account.leagueId, { totals: Object.fromEntries(totals), at: Date.now() });
  renderHome();
  renderDirectory();
  void loadOtherSummaries();
}

async function loadOtherSummaries() {
  const version = ++generation;
  const userId = account.userId;
  await Promise.all((account.leagues || []).filter((league) => league.league_id !== account.leagueId
    && Date.now() - (summaries.get(league.league_id)?.at || 0) > 120000).map(async (league) => {
    const result = await db.rpc('get_league_scores', { p_league_id: league.league_id });
    if (version !== generation || userId !== account.userId) return;
    summaries.set(league.league_id, { totals: result.error || result.data?.error ? null : result.data?.teams, at: Date.now() });
  }));
  if (version === generation && current) { renderTeams(); renderDirectory(); }
}

function linkFor(league, view = 'teams') {
  const url = new URL(location.href);
  url.search = ''; url.searchParams.set('league', league.league_id); url.hash = view;
  return url.href;
}
function sectionHead(title, detail = '') { return `<div class="section-heading"><div><h2>${html(title)}</h2>${detail ? `<p class="sub">${html(detail)}</p>` : ''}</div></div>`; }
function teamCard(league, directory = false) {
  const record = summaries.get(league.league_id);
  const standing = teamStanding(record?.totals, league.fantasy_team_id);
  const status = league.status === 'setup' ? 'Getting ready to draft' : league.status === 'drafting' ? 'Draft in progress' : 'Season in progress';
  const ownTeam = current?.data.teams?.find((team) => team.id === league.fantasy_team_id);
  const title = directory ? league.name : ownTeam?.team_name || league.team_name || league.name;
  const latest = current?.data.weeks.filter((week) => week.is_complete).at(-1);
  const last = league.league_id === account.leagueId && latest ? current.weekTotals?.get(`${latest.id}:${league.fantasy_team_id}`) : null;
  return `<a class="home-team-card ${directory ? 'directory-card' : ''}" href="${html(linkFor(league, directory ? 'league' : 'teams'))}"><div class="home-team-card-top"><span class="eyebrow">${html(directory ? status : league.name)}</span><span aria-hidden="true">↗</span></div><h3>${html(title)}</h3>${league.status === 'active' && standing ? `<div class="home-team-stats"><span><b>${standing.points.toLocaleString()}</b><small>Season points</small></span><span><b>${standing.rank}<i> / ${standing.count}</i></b><small>Place${standing.gap ? ` · ${standing.gap} behind` : ' · Leading'}</small></span></div>${last != null ? `<p class="home-team-last">Week ${latest.number} <strong>+${last}</strong></p>` : ''}` : `<p>${html(league.status === 'active' ? record && !record.totals ? 'Scores temporarily unavailable' : 'Loading scores…' : status)}</p>`}<div class="home-team-card-bottom">${directory ? 'Open league & standings' : league.status === 'active' ? 'Manage your team' : 'Enter draft room'} <span aria-hidden="true">→</span></div></a>`;
}
function renderTeams() {
  const target = $('[data-home-section="teams"]'); if (!target) return;
  const leagues = [...(account.leagues || [])].sort((a, b) => Number(b.league_id === account.leagueId) - Number(a.league_id === account.leagueId));
  target.innerHTML = sectionHead('Your Teams', 'One season. Every league you play in.') + `<div class="home-team-grid">${leagues.map((league) => teamCard(league)).join('')}</div>`;
}
function renderDirectory() {
  const target = $('#appLeagueDirectory'); if (!target) return;
  target.innerHTML = (account.leagues || []).map((league) => teamCard(league, true)).join('') || '<div class="card pad"><h2>Your league starts here</h2><p>Join friends with an invitation, or create a league of your own.</p></div>';
  $('#leagues [data-create-league]').disabled = !account.signedIn || Boolean(account.leaguesError);
  $('#leagues [data-join-league]').disabled = !account.signedIn || Boolean(account.leaguesError);
}
function reviewInvites() {
  $('#experienceSheet')?.close();
  if ($('#accountMenu').hidden) $('#auth').click();
  $('#accountMenu .workspace-invites-mini')?.scrollIntoView({ block: 'nearest' });
}
function renderInvitations() {
  const markup = invitations.length ? sectionHead('Invitations') + `<div class="card invitation-summary"><div><b>${invitations.length} invitation${invitations.length === 1 ? '' : 's'} waiting</b><p>${invitations.map((invite) => html(invite.league_name)).join(' · ')}</p></div><button type="button" data-review-invites>Review</button></div>` : '';
  for (const selector of ['[data-home-section="invitations"]', '#directoryInvitations']) {
    const element = $(selector); if (!element) continue;
    element.innerHTML = markup;
    element.querySelector('[data-review-invites]')?.addEventListener('click', reviewInvites);
  }
  if ($('#homeNotifications')) $('#homeNotifications').textContent = invitations.length ? `Notifications (${invitations.length})` : 'Notifications';
}

function renderHome() {
  if (!current) return;
  $('#memberOverview h1').textContent = 'Home';
  $('#standingsLeagueName').textContent = account.displayName ? `Welcome, ${account.displayName}` : 'Mirrorball Fantasy';
  $('#standingsSubtitle').textContent = 'Your teams, the show, and the moments that matter.';
  const hidden = hiddenResultsWeek();
  let banner = $('#spoilerBanner');
  if (!banner) { banner = document.createElement('div'); banner.id = 'spoilerBanner'; $('#appHomeFeed').before(banner); }
  banner.innerHTML = hidden ? `<div class="spoiler-banner" role="status"><div><b>Results are hidden</b><p>New scores have arrived. Reveal them when you’re ready.</p></div><button type="button" data-reveal-results>Show results</button></div>` : '';
  $('#homeResults').textContent = hidden ? 'Show results' : 'Hide results';
  $('#homeResults').disabled = !latestResultsWeek(current.data);
  renderTeams(); renderInvitations(); renderRecap(); renderOdds();
  for (const id of homeLayout.order) {
    const section = $(`[data-home-section="${id}"]`);
    section.hidden = homeLayout.hidden.includes(id);
    $('#appHomeFeed').append(section);
  }
  updateShowNight();
}

function updateShowNight() {
  const week = current.data.weeks.find((item) => !item.is_complete);
  if (!week) return;
  const clock = easternDateTime();
  const windows = airingWindows(week);
  const live = windows.some(([start, end]) => clock >= start && clock < end);
  const next = windows.find(([start]) => start > clock);
  const target = $('#episodeSpotlight');
  // The shared renderer supplies photos, counts and its existing Dances action.
  let status = target.querySelector('.home-airing-status');
  if (!status) { status = document.createElement('p'); status.className = 'home-airing-status'; target.append(status); }
  status.textContent = live ? 'On air now · Scores update as they arrive' : next
    ? `Next airing · ${new Intl.DateTimeFormat('en-US', { weekday: 'long', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(`${next[0].slice(0, 10)}T12:00Z`))} · ${Number(next[0].slice(11, 13)) % 12 || 12}:${next[0].slice(14, 16)} ${Number(next[0].slice(11, 13)) >= 12 ? 'PM' : 'AM'} Eastern`
    : 'Airing finished · Waiting for the week’s final results';
}

function renderRecap() {
  const recap = weekRecap(current.data, hiddenResultsWeek());
  const danceSection = $('[data-home-section="danceOfWeek"]');
  const sentSection = $('[data-home-section="sentHome"]');
  danceSection.innerHTML = ''; sentSection.innerHTML = '';
  if (!recap) return;
  if (recap.top.length) {
    danceSection.innerHTML = sectionHead(recap.top.length > 1 ? 'Dances of the Week' : 'Dance of the Week', `Week ${recap.week.number} · ${recap.week.title || recap.week.theme || 'The highest judges’ scores'}`)
      + `<div class="home-recap-grid">${recap.top.map(({ dance, title, total, maximum }) => {
        const photo = danceCardPhotoFor(recap.week.number, title, dance.airing_night) || couplePhotoFor(title);
        return `<button class="home-recap-card" data-home-dance="${html(dance.id)}">${photo ? `<img src="${html(photo)}" alt="${html(title)}" loading="lazy">` : '<div class="recap-no-photo" aria-hidden="true">★</div>'}<span class="recap-caption"><span><small>${html(dance.dance_type)}</small><b>${html(title)}</b></span><strong>${total}<small> / ${maximum}</small></strong></span></button>`;
      }).join('')}</div>`;
    danceSection.querySelectorAll('[data-home-dance]').forEach((button) => { button.onclick = () => current.openDance?.(button.dataset.homeDance); });
  }
  if (recap.eliminated.length) {
    sentSection.innerHTML = sectionHead('Sent Home', `Week ${recap.week.number}`) + `<div class="home-results-list">${recap.eliminated.map(({ dance, title }) => `<button type="button" data-home-dance="${html(dance.id)}"><span class="result-star" aria-hidden="true">✦</span><span><b>${html(title)}</b><small>Thank you for the dances</small></span><span aria-hidden="true">›</span></button>`).join('')}</div>`;
    sentSection.querySelectorAll('[data-home-dance]').forEach((button) => { button.onclick = () => current.openDance?.(button.dataset.homeDance); });
  }
}

function renderOdds() {
  const { data } = current;
  const rows = activePartnershipPredictionRows(data.marketPredictions || [], data.pairs, data.cast);
  const week = data.weeks.find((item) => !item.is_complete);
  for (const [section, kind, title] of [['jeopardy', 'elimination', 'Elimination Odds'], ['contenders', 'winner', 'Chances to Win']]) {
    const element = $(`[data-home-section="${section}"]`);
    const candidates = hiddenResultsWeek() ? [] : rows.filter((row) => row.market_kind === kind && (kind === 'elimination'
      ? weeklyPredictionFor(row.cast_member_id, week, rows)?.market_ticker === row.market_ticker : isActivePrediction(row)))
      .sort((a, b) => Number(b.percent) - Number(a.percent)).slice(0, 3);
    element.innerHTML = candidates.length ? sectionHead(title, kind === 'elimination' ? `Week ${week.number} · Market estimates, not results` : 'Market estimates, not results')
      + `<div class="home-odds-list">${candidates.map((row) => {
        const star = data.cast.find((member) => member.id === row.cast_member_id);
        const pair = data.pairs.find((item) => item.star_id === star?.id);
        const pro = data.cast.find((member) => member.id === pair?.pro_id);
        return `<button type="button" data-home-cast="${html(star?.id)}"><span class="odds-ring ${kind}" style="--percent:${Number(row.percent)}%"><b>${predictionPercent(row.percent)}</b></span><span><b>${html(star?.name)}</b><small>${html(pro?.name || '')}</small></span><span aria-hidden="true">›</span></button>`;
      }).join('')}</div>` : '';
    element.querySelectorAll('[data-home-cast]').forEach((button) => { button.onclick = () => current.openCast?.(button.dataset.homeCast); });
  }
}

function customizeHome() {
  sheet('Customize Home', '<p class="sub">Choose what appears on Home and arrange it your way. Saved in this browser.</p><div id="homeLayoutOptions"></div><button class="secondary" id="resetHomeLayout">Reset to default</button>');
  const draw = () => {
    $('#homeLayoutOptions').innerHTML = homeLayout.order.map((id, index) => {
      const [, title, description] = homeSections.find((section) => section[0] === id);
      return `<div class="layout-option"><label><input type="checkbox" data-home-toggle="${id}" ${homeLayout.hidden.includes(id) ? '' : 'checked'}><span><b>${title}</b><small>${description}</small></span></label><div><button class="secondary" data-move="${id}" data-direction="-1" ${index ? '' : 'disabled'} aria-label="Move ${title} up">↑</button><button class="secondary" data-move="${id}" data-direction="1" ${index === homeLayout.order.length - 1 ? 'disabled' : ''} aria-label="Move ${title} down">↓</button></div></div>`;
    }).join('');
    $('#homeLayoutOptions').onchange = (event) => {
      const id = event.target.dataset.homeToggle; if (!id) return;
      homeLayout.hidden = event.target.checked ? homeLayout.hidden.filter((item) => item !== id) : [...homeLayout.hidden, id];
      saveLayout();
    };
    $('#homeLayoutOptions').onclick = (event) => {
      const button = event.target.closest('[data-move]'); if (!button) return;
      const from = homeLayout.order.indexOf(button.dataset.move); const to = from + Number(button.dataset.direction);
      if (to < 0 || to >= homeLayout.order.length) return;
      [homeLayout.order[from], homeLayout.order[to]] = [homeLayout.order[to], homeLayout.order[from]];
      saveLayout(); draw();
      $(`[data-move="${button.dataset.move}"][data-direction="${button.dataset.direction}"]`)?.focus();
    };
  };
  const saveLayout = () => { storage.write(layoutKey(), homeLayout); if (current) renderHome(); };
  $('#resetHomeLayout').onclick = () => { homeLayout = normalizeHomeLayout(); saveLayout(); draw(); };
  draw();
}

function applyPalette(value) {
  document.body.dataset.palette = ['amethyst', 'sapphire', 'emerald', 'pearl-rose'].includes(value) ? value : 'amethyst';
}
function preferences() {
  sheet('Appearance & spoilers', `<p class="sub">Make this browser feel like your app. These preferences stay on this device.</p><label>Color palette<select id="websitePalette"><option value="amethyst">Amethyst</option><option value="sapphire">Sapphire</option><option value="emerald">Emerald</option><option value="pearl-rose">Pearl Rose</option></select></label><label class="preference-toggle"><input id="spoilerWarnings" type="checkbox" ${spoilerWarningsEnabled() ? 'checked' : ''}><span><b>Warn about new results</b><small>Hide new judges’ scores and cast points until you reveal them. League standings remain visible.</small></span></label><p class="sub">You can also hide or reveal the latest results using the button on Home.</p>`);
  $('#websitePalette').value = document.body.dataset.palette;
  $('#websitePalette').onchange = (event) => { applyPalette(event.target.value); storage.write('mirrorball-web-palette', event.target.value); };
  $('#spoilerWarnings').onchange = (event) => setSpoilerWarnings(event.target.checked);
}
function notifications() {
  sheet('Notifications', `${invitations.length ? `<div class="card pad"><h3>${invitations.length} pending invitation${invitations.length === 1 ? '' : 's'}</h3><p>${invitations.map((invite) => html(invite.league_name)).join(', ')}</p><button data-review-invites>Review invitations</button></div>` : '<p class="sub">No pending league invitations.</p>'}${account.fantasyTeamId ? '<a class="notification-link" href="#teams" id="notificationTeam">Open your team for draft turns and trade offers →</a>' : ''}${hiddenResultsWeek() ? '<p>New show results are available and hidden until you’re ready.</p><button data-reveal-results>Show results</button>' : ''}`);
  $('#experienceSheet [data-review-invites]')?.addEventListener('click', reviewInvites);
  $('#notificationTeam')?.addEventListener('click', () => $('#experienceSheet').close());
}

const lessons = [
  ['Welcome to Mirrorball', 'Draft a cast. Follow the show. Play with friends.', 'Create or join a league with 3–5 managers. Each manager builds a team from the same cast pool. Your teams and the latest show highlights are on Home; standings and league settings are in Leagues.'],
  ['Build your team', 'A snake draft gives everyone a turn.', 'The pick order reverses each round. Roster sizes are 12 for three managers, 10 for four, and 8 for five. Active Stars and Pros share a combined allowance; Bonus cast fill the remaining spots. The draft screen shows your current limits. Auto-draft picks randomly from the next eligible category. Your commissioner controls the draft timer.'],
  ['Make every dance count', 'Judges’ scores + cast appearances.', 'Both competing partners normally earn the judges’ total. Recorded appearances earn the current rate for the cast member’s saved role that week. Injured Pros earn half the dance score, rounded up; suspended dancers earn zero. A replacement earns the full score, or half if they also dance with their own couple that week. Replacements do not also earn an appearance for the same dance.'],
  ['Trade and swap', 'Build the team you want within today’s limits.', 'Open your team to propose a one-for-one trade or swap with available cast. If a changing cast pool puts you over a category limit, you may keep the roster, but moves must correct an over-limit category. Trades and swaps lock when an airing starts and reopen after the week is marked complete. A draft already underway can finish.'],
  ['After elimination night', 'Your cast stays on your fantasy team.', 'Eliminated cast keep their regular scoring roles through elimination night. Their new appearance rates start the following week. Past rosters stay attached to the teams that held them then, while current role rates price recorded appearances. The original league keeps its special roster rules.'],
];
function tutorial(index = 0) {
  const [title, subtitle, copy] = lessons[index];
  sheet(title, `<div class="tutorial-art" aria-hidden="true">${['✦', '♧', '★', '⇄', '✧'][index]}</div><p class="eyebrow">${index + 1} of ${lessons.length}</p><h3>${subtitle}</h3><p class="tutorial-copy">${copy}</p><div class="tutorial-progress" aria-hidden="true">${lessons.map((_, i) => `<i class="${i === index ? 'selected' : ''}"></i>`).join('')}</div><div class="modal-actions"><button id="tutorialBack" class="secondary" ${index === 0 ? 'disabled' : ''}>Back</button><button id="tutorialNext">${index === lessons.length - 1 ? 'Let’s play' : 'Next'}</button></div>`);
  $('#tutorialBack').onclick = () => tutorial(index - 1);
  $('#tutorialNext').onclick = () => index === lessons.length - 1 ? $('#experienceSheet').close() : tutorial(index + 1);
}

function safeMusicURL(value, host) {
  try { const url = new URL(value); return url.protocol === 'https:' && url.hostname === host ? url.href : null; } catch { return null; }
}

export function enhanceDanceDetail(container, dance, data, refreshDetail = null) {
  if (!configured) return;
  const heading = container.querySelector('.dance-detail-head');
  if (!heading) return;
  container.querySelector('[data-reveal-results]')?.addEventListener('click', (event) => {
    event.stopPropagation();
    setHiddenResults(null);
    refreshDetail?.();
  });
  const actions = document.createElement('div'); actions.className = 'dance-discovery-actions';
  if (dance.song_title && enabled('music_links')) {
    const button = document.createElement('button'); button.className = 'secondary'; button.textContent = 'Listen to the music';
    button.onclick = () => {
      const songs = danceSongList(dance).entries.filter((entry) => entry.title);
      sheet('Listen to the music', songs.map(({ title, artist }) => {
        const term = encodeURIComponent([title, artist].filter(Boolean).join(' '));
        const apple = songs.length === 1 && safeMusicURL(dance.apple_music_url, 'music.apple.com') || `https://music.apple.com/us/search?term=${term}`;
        const spotify = songs.length === 1 && safeMusicURL(dance.spotify_url, 'open.spotify.com') || `https://open.spotify.com/search/${term}`;
        return `<div class="music-options"><h3>${html(title)}</h3><p>${html(artist)}</p><div><a href="${html(apple)}" target="_blank" rel="noopener noreferrer">Apple Music ↗</a><a href="${html(spotify)}" target="_blank" rel="noopener noreferrer">Spotify ↗</a></div></div>`;
      }).join(''));
    };
    actions.append(button);
  }
  if (dance.dance_type && dance.kind === 'competitive' && enabled('dance_style_info')) {
    const button = document.createElement('button'); button.className = 'secondary'; button.textContent = `About ${dance.dance_type}`;
    button.onclick = () => {
      const parsed = splitDanceType(dance.dance_type);
      const names = parsed.type === 'Fusion' ? ['Fusion', parsed.first, parsed.second] : [parsed.type];
      const matching = data.dances.filter((item) => item.kind === 'competitive' && item.week_id !== hiddenResultsWeek() && (item.dance_type === dance.dance_type || parsed.type !== 'Fusion' && [splitDanceType(item.dance_type).first, splitDanceType(item.dance_type).second].includes(parsed.type)));
      const scored = matching.map((item) => data.scores.filter((score) => score.dance_id === item.id)).filter((scores) => scores.length).map((scores) => scores.reduce((sum, score) => sum + Number(score.score), 0));
      sheet(dance.dance_type, names.map((name) => { const style = styles.find((item) => item.name === name); return `<section class="style-description"><p class="eyebrow">${html(style?.type || 'Dance style')}</p><h3>${html(name)}</h3><p>${html(style?.description || 'No description available yet.')}</p></section>`; }).join('') + `<div class="style-statistics"><span><b>${matching.length}</b>Dances this season</span>${scored.length ? `<span><b>${Math.max(...scored)}</b>Best judges’ total</span><span><b>${(scored.reduce((a, b) => a + b, 0) / scored.length).toFixed(1)}</b>Average total</span>` : ''}</div>`);
    };
    actions.append(button);
  }
  if (actions.children.length) heading.append(actions);
  const changes = (data.castChanges || []).filter((change) => change.dance_id === dance.id);
  if (dance.special_note || changes.length) {
    const note = document.createElement('section'); note.className = 'dance-special-note';
    note.innerHTML = `<h3>About this performance</h3>${dance.special_note ? `<p>${html(dance.special_note)}</p>` : ''}${changes.map((change) => {
      const original = data.cast.find((cast) => cast.id === change.cast_member_id);
      const replacement = data.cast.find((cast) => cast.id === change.replacement_cast_member_id);
      return `<p><b>${html(original?.name || 'Cast member')} · ${html(change.reason)}</b>${replacement ? `<br>${html(replacement.name)} performs in their place.` : ''}${change.description ? `<br>${html(change.description)}` : ''}</p>`;
    }).join('')}`;
    heading.after(note);
  }
}
