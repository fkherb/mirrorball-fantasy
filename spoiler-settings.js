import { resultSignature, latestResultsWeek } from './home-model.js?v=20261022-people-v117';

let state = { enabled: true, hiddenWeek: null, seen: null };
let accountKey = null;
let ownerSurface = false;
export function configureSpoilers(userId, owner = false) {
  ownerSurface = owner;
  const key = `mirrorball-web-spoilers:${userId || 'guest'}`;
  if (key === accountKey) return;
  accountKey = key;
  try { state = { enabled: true, hiddenWeek: null, seen: null, ...JSON.parse(localStorage.getItem(key) || '{}') }; }
  catch { state = { enabled: true, hiddenWeek: null, seen: null }; }
}
function save() { try { if (accountKey) localStorage.setItem(accountKey, JSON.stringify(state)); } catch { /* Private browsing may disable persistence. */ } }
export function observeResults(data) {
  if (ownerSurface || !accountKey) return;
  const signature = resultSignature(data);
  const week = latestResultsWeek(data);
  if (state.enabled && state.seen && state.seen !== signature && week) state.hiddenWeek = week.id;
  state.seen = signature;
  if (state.hiddenWeek && !data.weeks.some((item) => item.id === state.hiddenWeek)) state.hiddenWeek = null;
  save();
}
export function hiddenResultsWeek() { return !ownerSurface && state.enabled ? state.hiddenWeek : null; }
export function hidesResults(weekId = null) { return Boolean(hiddenResultsWeek() && (!weekId || hiddenResultsWeek() === weekId)); }
export function spoilerWarningsEnabled() { return state.enabled; }
export function setSpoilerWarnings(enabled) { state.enabled = enabled; if (!enabled) state.hiddenWeek = null; changed(); }
export function setHiddenResults(weekId) { state.hiddenWeek = weekId; if (weekId) state.enabled = true; changed(); }
function changed() { save(); if (typeof window !== 'undefined') window.dispatchEvent(new Event('mirrorball-spoilers-change')); }
export function hiddenScoreMarkup() { return '<span class="spoiler-value" aria-label="Result hidden">•••</span>'; }
export function spoilerRole(member, role = member?.role || '') {
  return member?.eliminated_week_id === hiddenResultsWeek() ? role.replace(/^Eliminated |^Elim /, '') : role;
}
