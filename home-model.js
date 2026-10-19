// Presentation-only models shared by the Home feed and its regression checks.
export const homeSections = Object.freeze([
  ['showNight', 'Show Night', 'The next episode and live dance progress'],
  ['teams', 'Your Teams', 'Your teams across all your leagues'],
  ['invitations', 'Invitations', 'League invitations waiting for you'],
  ['danceOfWeek', 'Dance of the Week', 'Last week’s highest judges’ scores'],
  ['sentHome', 'Sent Home', 'The latest completed elimination results'],
  ['jeopardy', 'Elimination Odds', 'The couples most at risk this week'],
  ['contenders', 'Chances to Win', 'The favorites for the Mirrorball'],
]);

export function normalizeHomeLayout(value = {}) {
  const known = homeSections.map(([id]) => id);
  const order = [...new Set((Array.isArray(value.order) ? value.order : []).filter((id) => known.includes(id)))];
  for (const id of known) if (!order.includes(id)) order.push(id);
  return { order, hidden: [...new Set((Array.isArray(value.hidden) ? value.hidden : []).filter((id) => known.includes(id)))] };
}

export function danceTitle(dance, data) {
  const pair = data.pairs.find((item) => item.id === dance.partnership_id);
  const names = pair && [pair.star_id, pair.pro_id].map((id) => data.cast.find((item) => item.id === id)?.name).filter(Boolean);
  return names?.length ? names.join(' & ') : dance.name || 'Performance';
}

export function weekRecap(data, hiddenWeek = null) {
  const week = [...data.weeks].filter((item) => item.is_complete && item.id !== hiddenWeek).sort((a, b) => b.number - a.number)[0];
  if (!week) return null;
  const dances = data.dances.filter((dance) => dance.week_id === week.id && dance.kind === 'competitive');
  const scored = dances.map((dance) => {
    const scores = data.scores.filter((score) => score.dance_id === dance.id);
    return { dance, title: danceTitle(dance, data), total: scores.reduce((sum, score) => sum + Number(score.score), 0), maximum: scores.length * 10 };
  }).filter((item) => item.maximum > 0);
  const best = Math.max(0, ...scored.map((item) => item.total));
  const eliminated = [...new Map(dances.filter((dance) => dance.elimination_result === true && dance.elimination_confirmed === true)
    .map((dance) => [dance.partnership_id, { dance, title: danceTitle(dance, data) }])).values()];
  return { week, top: scored.filter((item) => item.total === best), eliminated };
}

export function teamStanding(totals, teamId) {
  const entries = Object.entries(totals || {}).sort((a, b) => b[1] - a[1]);
  const own = entries.find((entry) => entry[0] === teamId);
  if (!own) return null;
  const points = Number(own[1]);
  const higher = entries.filter(([, value]) => Number(value) > points);
  return { points, rank: higher.length + 1, count: entries.length,
    gap: higher.length ? Number(higher.at(-1)[1]) - points : 0 };
}

export function resultSignature(data) {
  const competitive = new Set(data.dances.filter((dance) => dance.kind === 'competitive').map((dance) => dance.id));
  return JSON.stringify([
    data.scores.filter((score) => competitive.has(score.dance_id)).map((score) => `${score.dance_id}|${score.judge_name}|${score.score}`).sort(),
    data.cast.filter((member) => member.eliminated_week_id).map((member) => `${member.id}|${member.eliminated_week_id}`).sort(),
  ]);
}

export function latestResultsWeek(data) {
  const scored = new Set(data.scores.map((score) => score.dance_id));
  const ids = new Set(data.dances.filter((dance) => dance.kind === 'competitive' && scored.has(dance.id)).map((dance) => dance.week_id));
  for (const member of data.cast) if (member.eliminated_week_id) ids.add(member.eliminated_week_id);
  return [...data.weeks].filter((week) => ids.has(week.id)).sort((a, b) => b.number - a.number)[0] || null;
}
