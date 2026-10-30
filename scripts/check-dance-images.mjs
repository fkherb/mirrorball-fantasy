import assert from 'node:assert/strict';
import { readdirSync, existsSync, readFileSync } from 'node:fs';
import { danceImagesFor, danceCardPhotoFor, couplePhotoFor, refreshDanceImages, uploadedDancePhotos, dancePhotoSource } from '../dance-images.js';

for (const pair of [
  'Amber Glenn & Pasha Pashkov', 'Ciara Miller & Brandon Armstrong',
  'Conner Leavitt & Adele Zaikman', 'Connor Wood & Rylee Arnold',
  'Ezra Frech & Daniella Karagach', 'Giada De Laurentiis & Alan Bersten',
  'Guillermo Rodriguez & Witney Carson', 'Harry Shum Jr. & Jenna Johnson',
  'Jackson Olson & Emma Slater', 'Jenna Dewan & Val Chmerkovskiy',
  'Julia Stiles & Ezra Sosa', 'Maura Higgins & Mark Ballas',
  'Sarah Jane Nader & Hailey Bills', 'Tatyana Ali & Jan Ravnik',
  'Taylor Hanson & Britt Stewart', 'Tyler Cameron & Sharna Burgess',
]) {
  const photo = couplePhotoFor(pair);
  assert.ok(photo && existsSync(decodeURIComponent(photo)), `Missing couple placeholder: ${pair}`);
}

const manifestEntries = JSON.parse(readFileSync('dance-photo-manifest.json', 'utf8')).entries;
const uploadedUrls = [...uploadedDancePhotos(manifestEntries).values()].flat();
for (const week of [1, 2, 3]) {
  const folder = `Images/Dances/Week ${week}`;
  for (const filename of readdirSync(folder)) {
    // Skip results-night photos, sidecars and Finder files (.DS_Store isn't tracked).
    if (filename.startsWith('.') || filename.startsWith('Elimination-') || filename.endsWith('.source.json')) continue;
    assert.ok(uploadedUrls.some((url) => decodeURIComponent(url.split('?')[0]).endsWith(`${folder}/${filename}`)),
      `Unmapped: ${filename}`);
  }
}
assert.equal(uploadedDancePhotos(manifestEntries).get('2:eliminated pros')?.length, 2);
assert.equal(danceImagesFor(3, 'Amber Glenn & Pasha Pashkov').length, 0);
assert.equal(danceImagesFor(1, 'Symphony of Dance Performance').length, 0);
const tree = [
  { type: 'blob', path: 'Images/Dances/Week 3/Amber Glenn and Pasha Pashkov-2.jpg', sha: 'photo-two' },
  { type: 'blob', path: 'Images/Dances/Week 3/Amber Glenn and Pasha Pashkov-1.jpeg', sha: 'photo-one' },
  { type: 'blob', path: 'Images/Dances/Card/Week 3/Amber Glenn and Pasha Pashkov-1.webp', sha: 'card-one' },
  { type: 'blob', path: 'Images/Dances/Week 3/Elimination-1.jpeg', sha: 'editorial' },
  { type: 'blob', path: 'Images/Dances/Week 3/Other Pair-1.webp', sha: 'other' },
  { type: 'blob', path: 'Images/Dances/Week 3/notes.txt', sha: 'notes' },
];
assert.equal(uploadedDancePhotos(tree).size, 2);
const manifestFetcher = async (url) => url.includes('/git/trees/')
  ? { ok: false, status: 503 } : { ok: true, json: async () => ({ version: 1, entries: tree }) };
const originalWarn = console.warn;
try {
  console.warn = () => {}; // The simulated API outage is expected.
  assert.equal(await refreshDanceImages({ fetcher: manifestFetcher, now: 500000 }), true);
} finally {
  console.warn = originalWarn;
}
assert.match(danceCardPhotoFor(3, 'Amber Glenn & Pasha Pashkov'), /Card\/Week%203\/Amber%20Glenn%20and%20Pasha%20Pashkov-1\.webp\?v=card-one$/);
let fetchCount = 0;
const fetcher = async () => {
  fetchCount += 1;
  return { ok: true, json: async () => ({ tree, truncated: false }) };
};
assert.equal(await refreshDanceImages({ fetcher, force: true, now: 1000000 }), false);
const weekThree = danceImagesFor(3, 'Amber Glenn & Pasha Pashkov');
assert.equal(weekThree.length, 2);
assert.match(weekThree[0], /Amber%20Glenn%20and%20Pasha%20Pashkov-1\.jpeg\?v=photo-one$/);
assert.match(weekThree[1], /Amber%20Glenn%20and%20Pasha%20Pashkov-2\.jpg\?v=photo-two$/);
assert.equal(danceImagesFor(3, 'Unmatched Pair').length, 0);
assert.equal(await refreshDanceImages({ fetcher, now: 1000001 }), false);
assert.equal(fetchCount, 1);
const currentManifestFetcher = async () => ({ ok: true, json: async () => ({ tree: manifestEntries, truncated: false }) });
assert.equal(await refreshDanceImages({ fetcher: currentManifestFetcher, force: true, now: 2000000 }), true);
assert.equal(danceImagesFor(1, 'Amber Glenn & Pasha Pashkov', 2).length, 3);
assert.equal(danceImagesFor(1, 'Amber Glenn & Pasha Pashkov', 1).length, 0);
assert.match(danceCardPhotoFor(1, 'Amber Glenn & Pasha Pashkov', 2), /Amber%20Glenn%20and%20Pasha%20Pashkov-Night%202-1\.webp/);
assert.match(danceImagesFor(1, 'Opening Number', 1)[0], /Opening%20Number-Night%201-1\.jpg/);
assert.match(danceImagesFor(1, 'Troupe', 2)[0], /Troupe-Night%202-1\.jpg/);
assert.equal(danceImagesFor(1, 'Opening Number').length, 0, 'Unassigned dances must not mix the two nights.');
assert.ok(danceImagesFor(1, 'Symphony of Dance Performance', 2).length > 0);
assert.ok(danceImagesFor(1, 'DWTS Next Pro', 1).length > 0);
assert.equal(danceImagesFor(1, 'DWTS Next Pro Dance', 1).length, 0);
assert.equal(danceImagesFor(2, 'Eliminated Pros').length, 2);
assert.equal(danceImagesFor(3, 'Troupe Break').length, 1);
assert.equal(danceImagesFor(3, 'Troupe').length, 0, 'A different performance title must not inherit its photos.');
assert.ok(manifestEntries.every((item) => !item.path.startsWith('Videos/')), 'Photo discovery must not index legacy video files.');
console.log('Existing and automatically discovered dance photos verified.');
const sourcePath = 'Images/Dances/Week 5/Amber Glenn and Pasha Pashkov-1.jpeg';
await refreshDanceImages({ force: true, fetcher: async () => ({ ok: true,
  json: async () => ({ tree: [{ path: sourcePath, sha: 'photo' }, { path: `${sourcePath}.source.json`, sha: 'source' }] }) }) });
const imported = danceImagesFor(5, 'Amber Glenn & Pasha Pashkov')[0];
const provenance = { version: 1, provider: 'X', author: 'officialdwts', post_id: '123',
  post_url: 'https://x.com/officialdwts/status/123', image_path: sourcePath };
const sourceFetcher = (data) => async () => ({ ok: true, json: async () => data });
assert.deepEqual(await dancePhotoSource(imported, sourceFetcher(provenance)), provenance);
assert.equal(await dancePhotoSource(imported, sourceFetcher({ ...provenance, post_url: 'javascript:alert(1)' })), null);
assert.equal(await dancePhotoSource('https://evil.example/photo.jpg', () => { throw new Error('Must not fetch'); }), null);

// Team photos ("<title> Team Photo-N") follow the dance's own photos and stand in until they're up.
{
  const teamTree = [
    { type: 'blob', path: 'Images/Dances/Week 8/Team Slaytopia Team Photo-1.jpg', sha: 'team-1' },
    { type: 'blob', path: 'Images/Dances/Card/Week 8/Team Slaytopia Team Photo-1.webp', sha: 'team-card' },
  ];
  const fetchTree = (entries) => async () => ({ ok: true, json: async () => ({ tree: entries }) });
  await refreshDanceImages({ force: true, fetcher: fetchTree(teamTree), now: 9_000_000 });
  assert.deepEqual(danceImagesFor(8, 'Team Slaytopia').map((url) => url.split('?v=')[1]), ['team-1']);
  assert.match(danceCardPhotoFor(8, 'Team Slaytopia'), /Team%20Slaytopia%20Team%20Photo-1\.webp/);
  await refreshDanceImages({ force: true, now: 9_500_000, fetcher: fetchTree([...teamTree,
    { type: 'blob', path: 'Images/Dances/Week 8/Team Slaytopia-1.jpg', sha: 'dance-1' },
    { type: 'blob', path: 'Images/Dances/Card/Week 8/Team Slaytopia-1.webp', sha: 'dance-card' }]) });
  assert.deepEqual(danceImagesFor(8, 'Team Slaytopia').map((url) => url.split('?v=')[1]), ['dance-1', 'team-1']);
  assert.match(danceCardPhotoFor(8, 'Team Slaytopia'), /Card\/Week%208\/Team%20Slaytopia-1\.webp/);
}
console.log('Team photos verified.');
