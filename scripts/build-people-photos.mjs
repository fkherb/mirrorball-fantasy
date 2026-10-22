// Cast and guest photos from the Assets folders.
//
//   Assets/<Pros|Stars|Bonus|Guest>/<Name>/<Name>.jpg|png   the source photo (-alt photos are ignored)
//   Assets/<Pros|Stars|Bonus|Guest>/<Name>/<Name>.txt       bio, then PERSONAL INFORMATION (HOMETOWN, BIRTHDATE)
//
// `node scripts/build-people-photos.mjs` syncs every folder to the database (people_assets, guests,
// cast bios) when DWTS_AUTOMATION_WORKER_SECRET is set, then renders each person's photos with the crops
// set in the app (defaults until then):
//   Images/People/<Name>/profile.webp   600×600   avatars, chips, rows
//   Images/People/<Name>/card.webp      1600×640  wide cards and banners
//   Images/People/<Name>/portrait.webp  960×1200  profile pages, Stories
//   Images/People/<Name>/full.webp      ≤2000px   the whole photo
// `--report` (after the files are pushed) records the renders so the app and site load them (?v=photo_version).
// `--check` verifies every manifest entry's files exist.
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import sharp from 'sharp';

const root = new URL('../', import.meta.url).pathname;
const assetsDir = path.join(root, 'Assets');
const outputDir = path.join(root, 'Images', 'People');
const manifestPath = path.join(root, 'people-photo-manifest.json');
const renderedPath = process.env.PEOPLE_RENDERED_FILE || path.join(tmpdir(), 'people-rendered.json');
const categories = ['Pros', 'Stars', 'Bonus', 'Guest'];
export const VARIANTS = {
  profile: { width: 600, height: 600, fallback: { x: 50, y: 10, zoom: 2.2 } },
  card: { width: 1600, height: 640, fallback: { x: 50, y: 10, zoom: 1 } },
  portrait: { width: 960, height: 1200, fallback: { x: 50, y: 8, zoom: 1 } },
};
const FULL_MAX = 2000;
const hash = (value) => createHash('sha256').update(value).digest('hex').slice(0, 16);
const apiUrl = process.env.SUPABASE_URL && `${process.env.SUPABASE_URL.replace(/\/$/, '')}/functions/v1/dwts-automation-worker`;
const secret = process.env.DWTS_AUTOMATION_WORKER_SECRET || '';

async function api(action, body) {
  const response = await fetch(apiUrl, {
    method: 'POST', headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: JSON.stringify({ worker: 'people-photos', action, ...body }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${action} failed (${response.status}): ${data.error || 'unknown error'}`);
  return data;
}

/** Bio text: the paragraphs before CAREER HIGHLIGHTS / PERSONAL INFORMATION, unwrapped. */
export function parseBio(text) {
  const clean = text.replace(/\r/g, '');
  const [body] = clean.split(/^\s*(?:CAREER HIGHLIGHTS|PERSONAL INFORMATION)\s*$/m);
  const bio = body.split(/\n\s*\n/).map((paragraph) => paragraph.split('\n').map((line) => line.trim()).join(' ').trim())
    .filter(Boolean).join('\n\n');
  const field = (label) => clean.match(new RegExp(`^\\s*${label}:[ \\t]*(.*)$`, 'mi'))?.[1].trim() || '';
  return { bio, hometown: field('HOMETOWN'), birthdate: field('BIRTHDATE') };
}

/** The crop rectangle (in source pixels) a PhotoFrame {x, y, zoom} shows in a width×height box.
 *  Same math as PhotoLayout.layout in the app and cast-avatar-frame.js on the site. */
export function cropRect(source, box, frame) {
  const cover = Math.max(box.width / source.width, box.height / source.height);
  const baseW = source.width * cover, baseH = source.height * cover;
  const zoom = Math.max(1, Number(frame.zoom) || 1);
  const fx = Math.min(100, Math.max(0, Number(frame.x ?? 50))), fy = Math.min(100, Math.max(0, Number(frame.y ?? 50)));
  const baseX = (box.width - baseW) * fx / 100, baseY = (box.height - baseH) * fy / 100;
  const originX = box.width * fx / 100, originY = box.height * fy / 100;
  const minX = originX - (originX - baseX) * zoom, minY = originY - (originY - baseY) * zoom;
  const scale = (baseW * zoom) / source.width;
  let left = Math.round(-minX / scale), top = Math.round(-minY / scale);
  const width = Math.min(source.width, Math.round(box.width / scale)), height = Math.min(source.height, Math.round(box.height / scale));
  left = Math.min(Math.max(0, left), source.width - width);
  top = Math.min(Math.max(0, top), source.height - height);
  return { left, top, width, height };
}

const cropsFor = (saved = {}) => Object.fromEntries(Object.entries(VARIANTS).map(([key, variant]) => {
  const value = saved?.[key];
  return [key, value && typeof value === 'object'
    ? { x: Number(value.x ?? variant.fallback.x), y: Number(value.y ?? variant.fallback.y), zoom: Number(value.zoom ?? variant.fallback.zoom) }
    : { ...variant.fallback }];
}));

async function exists(file) { try { await stat(file); return true; } catch { return false; } }

async function scanFolders() {
  const people = [];
  for (const category of categories) {
    const dir = path.join(assetsDir, category);
    const names = (await readdir(dir, { withFileTypes: true }).catch(() => [])).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
    for (const name of names) {
      const folderPath = path.join(dir, name);
      const files = await readdir(folderPath);
      const stem = name.replace(/\.+$/, '');
      const photo = files.find((file) => /\.(jpe?g|png)$/i.test(file) && file.replace(/\.[^.]+$/, '').replace(/\.+$/, '') === stem);
      const textFile = files.find((file) => file.toLowerCase() === `${name.toLowerCase()}.txt`) || files.find((file) => /\.txt$/i.test(file));
      const info = textFile ? parseBio(await readFile(path.join(folderPath, textFile), 'utf8')) : { bio: '', hometown: '', birthdate: '' };
      const entry = { folder: `Assets/${category}/${name}`, category, name, ...info, source_photo: '', source_sha: '', width: null, height: null };
      if (photo) {
        const bytes = await readFile(path.join(folderPath, photo));
        const meta = await sharp(bytes).rotate().metadata();
        const rotated = (meta.orientation || 1) >= 5;
        Object.assign(entry, { source_photo: `Assets/${category}/${name}/${photo}`, source_sha: hash(bytes),
          width: rotated ? meta.height : meta.width, height: rotated ? meta.width : meta.height });
      }
      people.push(entry);
    }
  }
  return people;
}

async function readJSON(file, fallback) { try { return JSON.parse(await readFile(file, 'utf8')); } catch { return fallback; } }

async function build() {
  const people = await scanFolders();
  const previous = await readJSON(manifestPath, { version: 1, entries: [] });
  const previousByFolder = new Map(previous.entries.map((entry) => [entry.folder, entry]));
  let database = null;
  if (apiUrl && secret) database = new Map((await api('people-sync', { people })).map((row) => [row.folder, row]));
  else console.log('No DWTS_AUTOMATION_WORKER_SECRET: rendering with the crops already in the manifest.');

  const entries = [], rendered = [];
  let count = 0;
  for (const person of people) {
    if (!person.source_photo) { console.warn(`No photo yet: ${person.folder}`); continue; }
    const row = database?.get(person.folder);
    const crops = cropsFor(row ? row.crops : previousByFolder.get(person.folder)?.crops);
    const key = hash(`${person.source_sha}:${JSON.stringify(crops)}`);
    const dir = path.join(outputDir, person.name);
    const files = Object.fromEntries([...Object.keys(VARIANTS), 'full'].map((variant) => [variant, `Images/People/${person.name}/${variant}.webp`]));
    const old = previousByFolder.get(person.folder);
    const present = (await Promise.all(Object.values(files).map((file) => exists(path.join(root, file))))).every(Boolean);
    if (!old || old.key !== key || !present) {
      await mkdir(dir, { recursive: true });
      const source = await readFile(path.join(root, person.source_photo));
      const size = { width: person.width, height: person.height };
      for (const [variant, box] of Object.entries(VARIANTS)) {
        const rect = cropRect(size, box, crops[variant]);
        await sharp(source).rotate().extract(rect).resize(box.width, box.height, { fit: 'fill' })
          .webp({ quality: 84, effort: 5 }).toFile(path.join(root, files[variant]));
      }
      await sharp(source).rotate().resize(FULL_MAX, FULL_MAX, { fit: 'inside', withoutEnlargement: true })
        .webp({ quality: 86, effort: 5 }).toFile(path.join(root, files.full));
      count++;
    }
    entries.push({ folder: person.folder, name: person.name, source: person.source_photo, sourceSha: person.source_sha, crops, key, files });
    // Tell the database once the files are pushed (also when it simply hasn't recorded this render yet).
    if (row && (JSON.stringify(cropsFor(row.rendered_crops)) !== JSON.stringify(crops) || !row.rendered_crops || row.rendered_sha !== person.source_sha)) {
      rendered.push({ folder: person.folder, crops, source_sha: person.source_sha });
    }
  }
  await writeFile(manifestPath, `${JSON.stringify({ version: 1, entries }, null, 2)}\n`);
  await writeFile(renderedPath, JSON.stringify(rendered));
  console.log(`Rendered ${count} of ${entries.length} people; ${rendered.length} to record after push.`);
}

async function report() {
  const rendered = await readJSON(renderedPath, []);
  if (!rendered.length) { console.log('Nothing to record.'); return; }
  if (!apiUrl || !secret) throw new Error('Set SUPABASE_URL and DWTS_AUTOMATION_WORKER_SECRET to record renders.');
  console.log(`Recorded ${await api('people-rendered', { rendered })} renders.`);
}

async function check() {
  const manifest = await readJSON(manifestPath, null);
  if (!manifest) throw new Error('people-photo-manifest.json is missing. Run node scripts/build-people-photos.mjs.');
  const missing = [];
  for (const entry of manifest.entries) for (const file of Object.values(entry.files)) if (!(await exists(path.join(root, file)))) missing.push(file);
  if (missing.length) throw new Error(`Missing people photos:\n${missing.join('\n')}`);
  console.log(`Verified ${manifest.entries.length} people's photos.`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (process.argv.includes('--report')) await report();
  else if (process.argv.includes('--check')) await check();
  else await build();
}
