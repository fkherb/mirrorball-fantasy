import assert from 'node:assert/strict';
import { normalizeHomeLayout, homeSections, weekRecap, teamStanding, resultSignature, latestResultsWeek } from '../home-model.js';
import { competitiveAwards, scoreLeague, sharedAppearanceRate } from '../scoring.js';
import { configureSpoilers, observeResults, hidesResults, setHiddenResults, setSpoilerWarnings, spoilerRole } from '../spoiler-settings.js?v=20261024-late-v118';
import { danceCard, danceDetail } from '../postdraft-view.js';

assert.deepEqual(normalizeHomeLayout({ order: ['teams', 'teams', 'removed'], hidden: ['teams', 'bad'] }), {
  order: ['teams', ...homeSections.map(([id]) => id).filter((id) => id !== 'teams')], hidden: ['teams'],
});
assert.deepEqual(teamStanding({ a: 90, b: 90, c: 75 }, 'c'), { points: 75, rank: 3, count: 3, gap: 15 });
assert.equal(teamStanding({ a: 90, b: 90 }, 'b').rank, 1);
assert.equal(teamStanding(null, 'a'), null);
const surprise = { role: 'Surprise', surprise_base_role: 'Pro', custom_appearance_points: 9 };
assert.equal(sharedAppearanceRate(surprise, null, new Map([['Pro', 3]])), 5);
assert.equal(sharedAppearanceRate(surprise, null, new Map([['Pro', 3]]), true), 9, 'original league preserves custom Surprise rates');

const data = {
  league: { id: 'league' }, teams: [{ id: 'team' }],
  cast: [{ id: 'star', name: 'Star', role: 'Star' }, { id: 'pro', name: 'Pro', role: 'Pro' },
    { id: 'fill', name: 'Fill In', role: 'Pro' }, { id: 'star2', name: 'Other Star', role: 'Star' }],
  pairs: [{ id: 'pair', star_id: 'star', pro_id: 'pro' }, { id: 'pair2', star_id: 'star2', pro_id: 'fill' }],
  weeks: [{ id: 'w1', number: 1, is_complete: true }, { id: 'w2', number: 2, is_complete: true }],
  dances: [{ id: 'dance', week_id: 'w2', kind: 'competitive', partnership_id: 'pair', elimination_result: true, elimination_confirmed: true }],
  scores: [{ dance_id: 'dance', judge_name: 'Judge', score: 9 }],
  appearances: [{ dance_id: 'dance', cast_member_id: 'fill' }],
  castChanges: [{ dance_id: 'dance', cast_member_id: 'pro', replacement_cast_member_id: 'fill', reason: 'injured' }],
  roles: [{ name: 'Pro', appearance_points: 3 }], snapshots: [],
};
for (const week of data.weeks) for (const member of data.cast) data.snapshots.push({ week_id: week.id, cast_member_id: member.id, fantasy_team_id: 'team', cast_role: member.role });
const total = new Map([['dance', 9]]);
assert.deepEqual(competitiveAwards(data, total).awards.map((award) => [award.castId, award.points]), [['star', 9], ['pro', 5], ['fill', 9]]);
assert(competitiveAwards(data, total).skippedAppearances.has('dance:fill'));
assert.equal(scoreLeague(data, { leagueStatus: 'active', scoringStartsAfterWeek: 0 }).totalByTeam.get('team'), 23);
const suspended = { ...data, castChanges: [{ ...data.castChanges[0], reason: 'suspended' }] };
assert.equal(scoreLeague(suspended, { leagueStatus: 'active', scoringStartsAfterWeek: 0 }).totalByTeam.get('team'), 18);
const ownDance = { ...data, dances: [...data.dances, { id: 'own', week_id: 'w2', kind: 'competitive', partnership_id: 'pair2' }] };
assert.equal(competitiveAwards(ownDance, total).awards.find((award) => award.danceId === 'dance' && award.castId === 'fill').points, 5);
assert.throws(() => scoreLeague({ ...data, snapshots: data.snapshots.filter((row) => row.cast_member_id !== 'fill') }, { leagueStatus: 'active', scoringStartsAfterWeek: 0 }), /missing/);
const recap = weekRecap(data);
assert.equal(recap.top[0].total, 9);
assert.equal(recap.eliminated[0].title, 'Star & Pro');
assert.equal(weekRecap(data, 'w2').week.id, 'w1');
assert.equal(latestResultsWeek(data).id, 'w2');
assert.equal(resultSignature(data), resultSignature({ ...data, scores: [...data.scores].reverse() }));
assert.notEqual(resultSignature(data), resultSignature({ ...data, scores: [{ ...data.scores[0], score: 10 }] }));

const memory = new Map();
globalThis.localStorage = { getItem: (key) => memory.get(key), setItem: (key, value) => memory.set(key, value) };
configureSpoilers('viewer'); observeResults(data);
assert.equal(hidesResults(), false, 'first visit establishes a baseline');
observeResults({ ...data, scores: [{ ...data.scores[0], score: 10 }] });
assert.equal(hidesResults('w2'), true);
assert.equal(hidesResults('w1'), false);
assert.equal(spoilerRole({ role: 'Eliminated Pro', eliminated_week_id: 'w2' }), 'Pro');
const card = danceCard({ id: 'dance', kind: 'competitive', title: 'Pair', scores: [{ judge_name: 'Judge', score: 9 }], scoreImage: () => '9.png', week: { id: 'w2' } });
assert.match(card, /Scores hidden/);
assert.doesNotMatch(card, /Judges total 9|Judge: 9|9.png/);
const detail = danceDetail({ kind: 'competitive', title: 'Pair', scores: [{ judge_name: 'Judge', score: 9 }], teams: [], castRows: [], week: { id: 'w2' } });
assert.match(detail, /Reveal judges/);
assert.doesNotMatch(detail, /Judge: 9/);
setHiddenResults(null); assert.equal(hidesResults(), false);
setSpoilerWarnings(false); observeResults(data); assert.equal(hidesResults(), false);
configureSpoilers('another-viewer'); assert.equal(hidesResults(), false);
configureSpoilers('viewer', true); setHiddenResults('w2'); assert.equal(hidesResults(), false, 'owner scoring surfaces always show raw results');
console.log('App parity: layout, standings ties, recaps, replacements, scoring and spoiler isolation verified.');
