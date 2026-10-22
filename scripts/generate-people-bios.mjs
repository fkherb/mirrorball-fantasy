// Writes Assets/<Category>/<Name>/<Name>.txt from Wikipedia for each person whose bio was requested in
// the app (People & Photos → Generate bio). Never overwrites an existing .txt. The new file is only a
// draft: edit it in Assets if you like, then tap "Use Assets bio" in the app to make it live.
//
//   intro paragraphs (up to 3)     → bio
//   Wikidata place of birth (P19)  → HOMETOWN
//   Wikidata date of birth (P569)  → BIRTHDATE
//
// Run by .github/workflows/generate-people-bios.yml (repository_dispatch "people-bios").
// Writes the results to PEOPLE_BIOS_FILE; `--report` records them after the files are pushed.
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const root = new URL('../', import.meta.url).pathname;
const resultsPath = process.env.PEOPLE_BIOS_FILE || path.join(tmpdir(), 'people-bios.json');
const apiUrl = process.env.SUPABASE_URL && `${process.env.SUPABASE_URL.replace(/\/$/, '')}/functions/v1/dwts-automation-worker`;
const secret = process.env.DWTS_AUTOMATION_WORKER_SECRET || '';
const userAgent = 'MirrorballFantasyBios/1.0 (https://github.com/fkherb/mirrorball-fantasy)';
const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

async function api(action, body = {}) {
  const response = await fetch(apiUrl, {
    method: 'POST', headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: JSON.stringify({ worker: 'people-bios', action, ...body }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${action} failed (${response.status}): ${data.error || 'unknown error'}`);
  return data;
}

async function getJSON(url) {
  const response = await fetch(url, { headers: { 'user-agent': userAgent, accept: 'application/json' } });
  if (!response.ok) throw new Error(`${response.status} from ${new URL(url).host}`);
  return response.json();
}

/** The person's article: "<Name>", then "<Name> (dancer)"; disambiguation pages don't count. */
async function findArticle(name) {
  for (const title of [name, `${name} (dancer)`]) {
    const url = `https://en.wikipedia.org/w/api.php?action=query&format=json&redirects=1&prop=extracts|pageprops|info`
      + `&inprop=url&exintro=1&explaintext=1&titles=${encodeURIComponent(title)}`;
    const page = Object.values((await getJSON(url)).query?.pages || {})[0];
    if (!page || page.missing !== undefined || page.pageprops?.disambiguation !== undefined) continue;
    if (!page.extract?.trim()) continue;
    return page;
  }
  return null;
}

async function wikidataFacts(item) {
  if (!item) return { hometown: '', birthdate: '' };
  const entity = (await getJSON(`https://www.wikidata.org/wiki/Special:EntityData/${item}.json`)).entities?.[item];
  const claim = (property) => entity?.claims?.[property]?.[0]?.mainsnak?.datavalue?.value;
  const born = claim('P569')?.time?.match(/^\+(\d{4})-(\d{2})-(\d{2})/);
  const birthdate = born && born[2] !== '00' && born[3] !== '00' ? `${months[Number(born[2]) - 1]} ${Number(born[3])}, ${born[1]}` : '';
  let hometown = '';
  const place = claim('P19')?.id;
  if (place) {
    const placeEntity = (await getJSON(`https://www.wikidata.org/wiki/Special:EntityData/${place}.json`)).entities?.[place];
    // The English article title names the state or country ("American Fork, Utah"); the label alone doesn't.
    hometown = (placeEntity?.sitelinks?.enwiki?.title || placeEntity?.labels?.en?.value || '').replace(/\s*\(.*\)$/, '');
  }
  return { hometown, birthdate };
}

const wrap = (paragraph, width = 72) => paragraph.split(/\s+/).reduce((lines, word) => {
  const last = lines[lines.length - 1];
  if (last && `${last} ${word}`.length <= width) lines[lines.length - 1] = `${last} ${word}`;
  else lines.push(word);
  return lines;
}, []).join('\n');

/** Same layout as the hand-written files (parsed by parseBio in build-people-photos.mjs). */
export function bioFile({ paragraphs, hometown, birthdate, url }) {
  return `${paragraphs.map((paragraph) => wrap(paragraph)).join('\n\n')}\n\nCAREER HIGHLIGHTS\n\n\n`
    + `PERSONAL INFORMATION\nHOMETOWN: ${hometown}\nBIRTHDATE: ${birthdate}\nSOURCE: ${url} (CC BY-SA)\n`;
}

export async function generate(person) {
  const folder = path.join(root, person.folder);
  const files = await readdir(folder).catch(() => null);
  if (!files) return { ok: false, message: 'The folder is not in Assets.' };
  if (files.some((file) => /\.txt$/i.test(file))) return { ok: false, message: 'The folder already has a bio file.' };
  const page = await findArticle(person.name);
  if (!page) return { ok: false, message: `No Wikipedia article found for "${person.name}". Write ${person.name}.txt by hand.` };
  const paragraphs = page.extract.split(/\n+/).map((text) => text.replace(/\s*\([^()]*\bborn\b[^()]*\)/, '').replace(/\s+/g, ' ').trim())
    .filter((text) => text.length > 40).slice(0, 3);
  const facts = await wikidataFacts(page.pageprops?.wikibase_item).catch(() => ({ hometown: '', birthdate: '' }));
  await writeFile(path.join(folder, `${person.name}.txt`), bioFile({ paragraphs, ...facts, url: page.fullurl }));
  return { ok: true, message: `Written from Wikipedia (${page.title}). Review ${person.name}.txt, then tap Use Assets bio.` };
}

async function run() {
  if (!apiUrl || !secret) throw new Error('Set SUPABASE_URL and DWTS_AUTOMATION_WORKER_SECRET.');
  const requests = await api('people-bio-requests');
  const results = [];
  for (const person of requests) {
    let result;
    try { result = await generate(person); } catch (error) { result = { ok: false, message: `Wikipedia lookup failed: ${error.message}` }; }
    console.log(`${person.name}: ${result.message}`);
    results.push({ folder: person.folder, ...result });
  }
  await writeFile(resultsPath, JSON.stringify(results));
  console.log(`${results.filter((result) => result.ok).length} of ${requests.length} bios written.`);
}

async function report() {
  const results = JSON.parse(await readFile(resultsPath, 'utf8').catch(() => '[]'));
  if (!results.length) { console.log('Nothing to record.'); return; }
  console.log(`Recorded ${await api('people-bios-generated', { results })} bio results.`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (process.argv.includes('--report')) await report();
  else await run();
}
