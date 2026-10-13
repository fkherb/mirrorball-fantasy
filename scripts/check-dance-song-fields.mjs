import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { danceSongParts, danceSongLabel, joinDanceSong } from '../dance-song.js';
import { danceCard, danceDetail } from '../postdraft-view.js';

const read = (file) => readFile(new URL(`../${file}`, import.meta.url), 'utf8');
const [app, workspace, view, songModule] = await Promise.all(
  ['app.js', 'league-workspace.js', 'postdraft-view.js', 'dance-song.js'].map(read));

const row = {
  song: 'Outdated song by Outdated artist',
  song_title: '  Stand by Me  ',
  song_artist: '  Ben E. King  ',
};
assert.deepEqual(danceSongParts(row), { title: 'Stand by Me', artist: 'Ben E. King' });
assert.equal(danceSongLabel(row), 'Stand by Me by Ben E. King');
assert.deepEqual(danceSongParts(null), { title: '', artist: '' });
assert.deepEqual(danceSongParts({ song: row.song }), { title: '', artist: '' });
assert.equal(danceSongLabel({ song: row.song, song_title: null, song_artist: null }), '');
assert.equal(danceSongLabel({ song_title: 'Title only', song_artist: null }), 'Title only');
assert.equal(danceSongLabel({ song_title: null, song_artist: 'Artist only' }), 'Artist only');
assert.deepEqual(danceSongParts({ song_title: 'Title by the Sea', song_artist: 'Music by Friends' }),
  { title: 'Title by the Sea', artist: 'Music by Friends' }, 'Do not split legitimate text containing " by ".');
assert.equal(joinDanceSong(row.song_title, row.song_artist), 'Stand by Me by Ben E. King',
  'The existing save_dance_atomic contract must still receive the formatted value.');
assert.equal(joinDanceSong('', ''), '');

for (const kind of ['competitive', 'performance']) {
  const props = {
    id: 'separate-song', kind, title: 'Dance', danceType: 'Rumba',
    song: row.song, songTitle: row.song_title, songArtist: row.song_artist,
    scores: [], castNames: [], teams: [], castRows: [], imageFor: () => '',
  };
  const card = danceCard(props);
  const detail = danceDetail(props);
  for (const rendered of [card, detail]) {
    assert.match(rendered, /Stand by Me/);
    assert.match(rendered, /Ben E\. King/);
    assert.doesNotMatch(rendered, /Outdated/);
  }
  if (kind === 'competitive') {
    assert.match(card, /Stand by Me<i> by Ben E\. King<\/i>/,
      'Keep artist text separate so the existing one-line fitting behavior works.');
  }
  assert.doesNotMatch(danceCard({ ...props, songTitle: null, songArtist: null }), /Outdated/);
  assert.doesNotMatch(danceDetail({ ...props, songTitle: null, songArtist: null }), /Outdated/);
  const escaped = danceCard({ ...props, songTitle: '<Title>', songArtist: 'A & B' });
  assert.match(escaped, /&lt;Title&gt;/);
  assert.match(escaped, /A &amp; B/);
  assert.doesNotMatch(escaped, /<Title>/);
}

assert.doesNotMatch(app + workspace, /dance\.song\b|existingDance\??\.song\b/,
  'Website readers must never use the legacy combined database column.');
assert.doesNotMatch(app + workspace + view + songModule, /splitDanceSong|lastIndexOf\(' by '\)/);
assert.match(app, /const existingSong = danceSongParts\(existingDance\)/);
assert.match(app, /scoresOnly \? null : joinDanceSong/);
assert.match(app, /p_song: song/, 'Preserve the existing RPC and its database synchronization trigger.');
assert.match(app, /songTitle: dance\.song_title, songArtist: dance\.song_artist/);
assert.match(workspace, /songTitle: dance\.song_title, songArtist: dance\.song_artist/);
assert.match(app, /db\.from\('dances'\)\.select\('\*'\)\.eq\('week_id', week\.id\)/,
  'Score Desk must fetch the separate columns from the database.');
assert.match(workspace, /dances: db\.from\('dances'\)\.select\('\*'\)/,
  'Public dance cards must fetch the separate columns from the database.');
console.log('Separate database song/artist fields, formatting, escaping, and legacy-save compatibility verified.');
