import assert from 'node:assert/strict';
import { appearanceValue, calculateLeaguePoints, roleForWeek, scoreLeague, sharedAppearanceRate } from '../scoring.js';

const roleWeeks = [{ id: 'exit-week', number: 2 }, { id: 'later-week', number: 3 }];
const eliminatedStar = { role: 'Eliminated Star', eliminated_week_id: 'exit-week' };
assert.equal(roleForWeek(eliminatedStar, roleWeeks[0], roleWeeks), 'Star');
assert.equal(roleForWeek(eliminatedStar, roleWeeks[1], roleWeeks), 'Eliminated Star');
assert.equal(appearanceValue({ role: 'Pro', is_hough: true }, new Map([['Hough', { appearance_points: 7 }]]), roleWeeks[0], roleWeeks), 7);
const surprise = { role: 'Surprise', surprise_base_role: 'Troupe', custom_appearance_points: 99 };
assert.equal(appearanceValue(surprise, new Map([['Troupe', { appearance_points: 4 }]]), roleWeeks[0], roleWeeks), 6);
assert.equal(sharedAppearanceRate(surprise, { cast_role: 'Surprise', appearance_points: 99 }, new Map([['Troupe', 8]])), 10);

const fixture = {
  teams: [{ id: 'team-a' }, { id: 'team-b' }],
  cast: [
    { id: 'star', role: 'Eliminated Star' },
    { id: 'pro', role: 'Eliminated Pro' },
    { id: 'bonus', role: 'Troupe' },
  ],
  pairs: [{ id: 'pair', star_id: 'star', pro_id: 'pro', active: false }],
  weeks: [{ id: 'week-1', number: 1, is_complete: true }, { id: 'week-2', number: 2, is_complete: true }],
  dances: [
    { id: 'dance-1', week_id: 'week-1', kind: 'competitive', partnership_id: 'pair' },
    { id: 'dance-2', week_id: 'week-2', kind: 'competitive', partnership_id: 'pair' },
  ],
  scores: [
    { dance_id: 'dance-1', score: 7 }, { dance_id: 'dance-1', score: 8 },
    { dance_id: 'dance-1', score: 9 }, { dance_id: 'dance-1', score: 10 },
    { dance_id: 'dance-2', score: 6 }, { dance_id: 'dance-2', score: 7 },
  ],
  appearances: [
    { dance_id: 'dance-1', cast_member_id: 'bonus' },
    { dance_id: 'dance-2', cast_member_id: 'bonus' },
  ],
  roles: [{ id: 'troupe-rate', name: 'Troupe', appearance_points: 10 }],
  snapshots: [
    { week_id: 'week-1', cast_member_id: 'star', fantasy_team_id: 'team-a', cast_role: 'Star' },
    { week_id: 'week-1', cast_member_id: 'pro', fantasy_team_id: 'team-a', cast_role: 'Pro' },
    { week_id: 'week-1', cast_member_id: 'bonus', fantasy_team_id: 'team-b', cast_role: 'Troupe', appearance_points: 2 },
    { week_id: 'week-2', cast_member_id: 'star', fantasy_team_id: 'team-a', cast_role: 'Eliminated Star' },
    { week_id: 'week-2', cast_member_id: 'pro', fantasy_team_id: 'team-a', cast_role: 'Eliminated Pro' },
    { week_id: 'week-2', cast_member_id: 'bonus', fantasy_team_id: 'team-b', cast_role: 'Troupe', appearance_points: 5 },
  ],
};

const active = { leagueStatus: 'active', scoringStartsAfterWeek: 0 };
const scored = scoreLeague(fixture, active);
assert.equal(scored.totalByTeam.get('team-a'), 94, 'an inactive partnership still scores historical dances and guest-judge scores');
assert.equal(scored.totalByTeam.get('team-b'), 20, 'both past weeks use the current universal rate');
assert.equal(scored.pointsByWeekTeam.get('week-1:team-a'), 68);
assert.equal(scored.pointsByWeekTeam.get('week-2:team-a'), 26);
assert.deepEqual(scored.pointsByWeekCast.get('week-2:bonus'), { official: 0, appearances: 10 });

const lateStart = scoreLeague(fixture, { ...active, scoringStartsAfterWeek: 1 });
assert.equal(lateStart.totalByTeam.get('team-a'), 26);
assert.equal(lateStart.totalByTeam.get('team-b'), 10);
const rerated = scoreLeague({ ...fixture, roles: [{ id: 'troupe-rate', name: 'Troupe', appearance_points: 4 }] }, active);
assert.equal(rerated.totalByTeam.get('team-b'), 8, 'changing the global rate reprices recorded appearances in past weeks');
const surpriseFixture = {
  ...fixture,
  cast: fixture.cast.map((cast) => cast.id === 'bonus' ? { ...cast, ...surprise } : cast),
  snapshots: fixture.snapshots.map((snapshot) => snapshot.cast_member_id === 'bonus'
    ? { ...snapshot, cast_role: 'Surprise', appearance_points: 99 } : snapshot),
};
assert.equal(scoreLeague(surpriseFixture, active).totalByTeam.get('team-b'), 24);
assert.equal(scoreLeague({ ...surpriseFixture, roles: [{ id: 'troupe-rate', name: 'Troupe', appearance_points: 4 }] }, active)
  .totalByTeam.get('team-b'), 12, 'Surprise appearances in past weeks follow the updated base rate +2');
assert.equal(scoreLeague(fixture, { ...active, leagueStatus: 'drafting' }).totalByTeam.get('team-a'), 0);
assert.throws(() => scoreLeague({ ...fixture, snapshots: fixture.snapshots.filter((row) => row.week_id !== 'week-2') }, active), /missing this league’s roster snapshot/);
assert.throws(() => scoreLeague({ ...fixture, snapshots: fixture.snapshots.filter((row) => !(row.week_id === 'week-2' && row.cast_member_id === 'pro')) }, active), /missing a cast roster snapshot/);

// The original and shared routes must agree on global rates and saved roles.
const parityFixture = {
  ...fixture,
  roles: [{ id: 'troupe-rate', name: 'Troupe', appearance_points: 2 }],
  snapshots: fixture.snapshots.map((snapshot) => ({ ...snapshot, appearance_points: snapshot.cast_member_id === 'bonus' ? 2 : null })),
};
const original = calculateLeaguePoints({
  teams: parityFixture.teams,
  members: parityFixture.cast,
  roles: parityFixture.roles,
  partnerships: parityFixture.pairs,
  weeks: parityFixture.weeks,
  dances: parityFixture.dances,
  scores: parityFixture.scores,
  appearances: parityFixture.appearances,
  rosterSnapshots: parityFixture.snapshots,
});
const shared = scoreLeague(parityFixture, active);
for (const week of parityFixture.weeks) {
  for (const team of parityFixture.teams) {
    const originalTotal = [...(original.weekMemberPoints.get(week.id) || [])]
      .filter(([castId]) => parityFixture.snapshots.find((row) => row.week_id === week.id && row.cast_member_id === castId)?.fantasy_team_id === team.id)
      .reduce((sum, [, points]) => sum + points.official + points.appearances, 0);
    assert.equal(shared.pointsByWeekTeam.get(`${week.id}:${team.id}`) || 0, originalTotal);
  }
}

console.log('League scoring fixtures verified.');

// Injured / suspended dancers (dance_cast_changes) — keep in step with CastChangeScoringTests (iOS).
{
  const withFillIn = (castChanges, ownCouple = false) => ({
    ...fixture,
    cast: [...fixture.cast, { id: 'fill', role: 'Eliminated Pro' }, { id: 'star2', role: 'Star' }],
    roles: [...fixture.roles, { id: 'epro', name: 'Eliminated Pro', appearance_points: 6 }],
    appearances: [...fixture.appearances, { dance_id: 'dance-1', cast_member_id: 'fill' }],
    snapshots: [...fixture.snapshots,
      { week_id: 'week-1', cast_member_id: 'fill', fantasy_team_id: 'team-b', cast_role: 'Eliminated Pro' },
      { week_id: 'week-1', cast_member_id: 'star2', fantasy_team_id: 'team-b', cast_role: 'Star' },
      { week_id: 'week-2', cast_member_id: 'fill', fantasy_team_id: 'team-b', cast_role: 'Eliminated Pro' },
      { week_id: 'week-2', cast_member_id: 'star2', fantasy_team_id: 'team-b', cast_role: 'Star' }],
    pairs: ownCouple ? [...fixture.pairs, { id: 'pair2', star_id: 'star2', pro_id: 'fill', active: true }] : fixture.pairs,
    dances: ownCouple ? [...fixture.dances, { id: 'dance-3', week_id: 'week-1', kind: 'competitive', partnership_id: 'pair2' }] : fixture.dances,
    scores: ownCouple ? [...fixture.scores, { dance_id: 'dance-3', score: 5 }, { dance_id: 'dance-3', score: 5 }] : fixture.scores,
    castChanges,
  });
  const suspended = scoreLeague(withFillIn([{ dance_id: 'dance-1', cast_member_id: 'pro', reason: 'suspended', replacement_cast_member_id: 'fill' }]), active);
  assert.equal(suspended.totalByTeam.get('team-a'), 60, 'a suspended Pro earns nothing for that dance');
  assert.equal(suspended.totalByTeam.get('team-b'), 54, 'the fill-in earns the full score instead of the appearance');
  const injured = scoreLeague(withFillIn([{ dance_id: 'dance-1', cast_member_id: 'pro', reason: 'injured', replacement_cast_member_id: 'fill' }]), active);
  assert.equal(injured.pointsByWeekCast.get('week-1:pro').official, 17, 'an injured Pro keeps half, rounded up');
  assert.equal(injured.totalByTeam.get('team-a'), 77);
  const twice = scoreLeague(withFillIn([{ dance_id: 'dance-1', cast_member_id: 'pro', reason: 'suspended', replacement_cast_member_id: 'fill' }], true), active);
  assert.equal(twice.pointsByWeekCast.get('week-1:fill').official, 27, 'a fill-in who also danced with their own couple gets half');
  assert.equal(twice.totalByTeam.get('team-b'), 57);
  assert.equal(scoreLeague(withFillIn([{ dance_id: 'dance-1', cast_member_id: 'star', reason: 'injured' }]), active).totalByTeam.get('team-a'), 94);
  assert.equal(scoreLeague(withFillIn([{ dance_id: 'dance-1', cast_member_id: 'star', reason: 'suspended' }]), active).totalByTeam.get('team-a'), 60);
  assert.equal(scoreLeague(withFillIn([]), active).totalByTeam.get('team-b'), 26);
}
