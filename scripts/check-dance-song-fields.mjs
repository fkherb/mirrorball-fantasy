import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { danceSongParts, danceSongLabel, joinDanceSong, danceSongList } from '../dance-song.js';
import { danceCard, danceDetail, danceSongSummary } from '../postdraft-view.js';

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
  'Presentation can combine the separate values without parsing them.');
assert.equal(joinDanceSong('', ''), '');

const medley = { song_title: ' Nuevayol; Rude Boy; Humble ', song_artist: ' Bad Bunny; Rihanna; Kendrick Lamar ' };
assert.deepEqual(danceSongList(medley).entries, [
  { title: 'Nuevayol', artist: 'Bad Bunny' },
  { title: 'Rude Boy', artist: 'Rihanna' },
  { title: 'Humble', artist: 'Kendrick Lamar' },
]);
assert.equal(danceSongLabel(medley), 'Nuevayol by Bad Bunny · Rude Boy by Rihanna · Humble by Kendrick Lamar');
assert.deepEqual(danceSongList({ song_title: 'A;B;C', song_artist: 'X;;Z' }).entries,
  [{title:'A',artist:'X'},{title:'B',artist:''},{title:'C',artist:'Z'}], 'Empty credits must not shift artists.');
const unmatched = { song_title: 'A;B;C', song_artist: 'X;Y' };
assert.ok(danceSongList(unmatched).entries.every((entry) => !entry.artist));
assert.deepEqual(danceSongList(unmatched).artists, ['X','Y']);
assert.equal(danceSongLabel(unmatched), 'A · B · C · Artists: X / Y');
assert.equal(danceSongList({song_title:'Song',song_artist:'Artist A; Artist B'}).medley, false);
assert.equal(danceSongList(null).medley, false);
for (const kind of ['competitive', 'performance']) {
  const props = { kind, title: 'Opening Number', scores: [], teams: [], castRows: [],
    songTitle: medley.song_title, songArtist: medley.song_artist };
  assert.match(danceCard(props), /class="dance-medley-summary"/);
  const detail = danceDetail(props);
  assert.match(detail, /Medley · 3 songs/);
  assert.match(detail, /<strong>Rude Boy<\/strong><span>Rihanna<\/span>/);
  assert.doesNotMatch(detail, /Nuevayol; Rude Boy/);
  const mismatchDetail = danceDetail({...props,songTitle:'A;B;C',songArtist:'X;Y'});
  assert.match(mismatchDetail, /<b>Artists<\/b> X \/ Y/);
  const escaped = danceDetail({...props,songTitle:'<A>;B',songArtist:'<X>;Y'});
  assert.match(escaped, /&lt;A&gt;/);
  assert.doesNotMatch(escaped, /<A>|<X>/);
}
assert.match(danceSongSummary(medley), /Medley · Nuevayol \/ Rude Boy \/ Humble/);
assert.match(app, /danceSongSummary\(dance\)/, 'Score Desk shares medley formatting.');

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
assert.match(app, /db\.rpc\('save_dance_atomic_v2'/);
assert.match(app, /p_song_title: songTitle, p_song_artist: songArtist/);
assert.doesNotMatch(app, /p_song:|joinDanceSong/, 'The website must never combine song fields for saving.');
assert.match(app, /songTitle: dance\.song_title, songArtist: dance\.song_artist/);
assert.match(workspace, /songTitle: dance\.song_title, songArtist: dance\.song_artist/);
assert.match(app, /db\.from\('dances'\)\.select\('\*'\)\.eq\('week_id', week\.id\)/,
  'Score Desk must fetch the separate columns from the database.');
assert.match(workspace, /dances: db\.from\('dances'\)\.select\('\*'\)/,
  'Public dance cards must fetch the separate columns from the database.');
console.log('Separate database song/artist fields, formatting, escaping, and legacy-save compatibility verified.');
