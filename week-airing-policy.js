import { airingWindows, easternDateTime } from './market-prediction-model.js?v=20261019-app-parity-v115';

export function isTradeAiringLocked(weeks, now = Date.now()) {
  const clock = easternDateTime(now);
  return weeks.some((week) => !week.is_complete && airingWindows(week).some(([start]) => clock >= start));
}

export function isDraftAiringLocked() {
  // Draft turns may continue during an airing. Trade/free-agent locks remain.
  return false;
}

export function isDraftStartBlocked(weeks, now = Date.now()) {
  return isTradeAiringLocked(weeks, now);
}
