// Late-season formats: team dances, bonus rounds (dance-off, relay, marathon) and the labels on
// a couple's extra rounds. Same wording as the app (Dance.formatSubtitle / LeagueData.danceTitle).
export const MATCH_BONUS_TITLES = { dance_off: 'Dance-Off', relay: 'Relay', marathon: 'Marathon' };

/** The couples in a team dance or bonus round (dance_couples rows → partnerships). */
export function danceCouplesFor(dance, data) {
  const pairs = new Map((data.pairs || data.partnerships || []).map((pair) => [pair.id, pair]));
  return (data.danceCouples || []).filter((entry) => entry.dance_id === dance.id)
    .map((entry) => ({ ...entry, pair: pairs.get(entry.partnership_id) })).filter((entry) => entry.pair);
}

/** "Team Roar", "Amber vs Jenna", or the marathon's own title; null for other dances. */
export function specialDanceTitle(dance, data) {
  if (dance.kind === 'team') return String(dance.team_name || '').trim() || 'Team Dance';
  if (dance.kind !== 'bonus') return null;
  if (dance.bonus_kind === 'marathon') return dance.name || 'Marathon';
  const cast = new Map((data.cast || data.members || []).map((member) => [member.id, member]));
  const stars = danceCouplesFor(dance, data).map((entry) => cast.get(entry.pair.star_id)?.name?.split(/\s+/)[0]).filter(Boolean);
  return stars.length >= 2 ? stars.join(' vs ') : dance.name || MATCH_BONUS_TITLES[dance.bonus_kind] || 'Bonus round';
}

/** The small line above a special dance: "Instant Dance", "Dance-Off", "Relay", "Marathon", "Team Dance". */
export function formatSubtitle(dance) {
  if (dance.kind === 'bonus') return MATCH_BONUS_TITLES[dance.bonus_kind] || 'Bonus round';
  if (dance.kind === 'team') return 'Team Dance';
  return String(dance.round_label || '').trim() || null;
}
