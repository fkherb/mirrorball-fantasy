// match-dance-songs: finds Apple Music and Spotify links for dances whose song is
// pending a match. Deploy with JWT verification disabled; callers send the bearer
// secret kept in Vault as music_match_secret (the cron job reads it from there).
//
// Apple Music: iTunes Search API (no key). Keep results whose title and artist
// match, drop karaoke/live/tribute versions, then take the earliest release (the
// original recording). Spotify: the Spotify Web API (client-credentials search,
// same title/artist rules), only when SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET
// are set; otherwise Spotify stays empty and the app opens a Spotify search.
// (Odesli/song.link closed its public API, so it can't be used without a key.)

const supabaseUrl = Deno.env.get('SUPABASE_URL');
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const spotifyId = Deno.env.get('SPOTIFY_CLIENT_ID');
const spotifySecret = Deno.env.get('SPOTIFY_CLIENT_SECRET');

type Pending = { id: string; song_title: string; song_artist: string | null };
type ITunesTrack = {
  trackName?: string; artistName?: string; collectionName?: string;
  trackViewUrl?: string; releaseDate?: string; collectionType?: string;
  kind?: string; wrapperType?: string; collectionArtistName?: string;
};

class RateLimited extends Error {}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

async function rpc(name: string, args: Record<string, unknown>) {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: serviceKey!, authorization: `Bearer ${serviceKey!}`, 'content-type': 'application/json' },
    body: JSON.stringify(args),
  });
  if (!response.ok) throw new Error(`Supabase ${name} ${response.status}: ${await response.text()}`);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

/** Lowercase, no accents or punctuation, & → and. Drops "(feat. …)" and
 *  remaster / radio edit / single version notes, but keeps remix and club credits
 *  so those versions don't count as the song. */
export function normalize(value: string) {
  return value
    .normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[’‘`]/g, "'")
    .replace(/\s*[([]\s*(feat|ft|with)\.?\s[^)\]]*[)\]]/g, '')
    .replace(/\s+-\s+(\d{4}\s+)?(digital(ly)?\s+)?remaster(ed)?(\s+\d{4})?(\s+version)?\s*$/g, '')
    .replace(/\s*[([][^)\]]*\bremaster(ed)?\b[^)\]]*[)\]]/g, '')
    .replace(/\s*(-\s+|[([])\s*(radio edit|single version|album version|original version|the original version|mono|stereo|clean edit|clean|explicit)\s*[)\]]?\s*$/g, '')
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** "Shakira feat. Wyclef Jean" → "shakira"; "Hall & Oates" → "hall and oates" (no featured artists). */
export function primaryArtist(artist: string) {
  const main = artist.split(/\s+(?:feat\.?|ft\.?|featuring|with)\s+/i)[0];
  return normalize(main);
}

const fillerWords = new Set(['the', 'and', 'jr', 'sr']);
function artistTokens(value: string) {
  return new Set(value.split(' ').filter((word) => word && !fillerWords.has(word)));
}

/** Same act: one credit's words all appear in the other ("Hall & Oates" ~ "Daryl Hall & John Oates"). */
export function sameArtist(stored: string, credited: string) {
  const a = artistTokens(primaryArtist(stored));
  const b = artistTokens(normalize(credited));
  if (!a.size || !b.size) return false;
  const within = (small: Set<string>, big: Set<string>) => [...small].every((word) => big.has(word));
  return within(a, b) || within(b, a);
}

/** Titles compare after normalizing ("Whoomp! There It Is!" = "Whoomp! (There It Is)"). */
function titleKey(title: string) {
  return normalize(title);
}

const unwanted = /karaoke|tribute|instrumental|\blive\b|cover|made famous|in the style of|originally performed|backing track|lullaby|piano version|acoustic|a cappella|acapella|sped up|slowed/i;

const compilation = /\b(hits|best of|greatest|collection|essential|anthology|ultimate|playlist|songs|now that|vol\.?|volume|\d0'?s|party|workout|soundtrack|remixes)\b/i;

/** Without a trailing "(…)" / "[…]": "Exhale (Shoop Shoop)" → "exhale shoop shoop" → "exhale". */
function titleCore(title: string) {
  return normalize(title.replace(/\s*[([][^)\]]*[)\]]\s*$/, ''));
}

/** 0 = same act exactly, 1 = the act with others (a duet), 2 = no match. */
function artistRank(stored: string, credited: string) {
  if (!sameArtist(stored, credited)) return 2;
  const a = artistTokens(primaryArtist(stored));
  const b = artistTokens(normalize(credited));
  return a.size === b.size ? 0 : 1;
}

const altVersion = /\b(remix|mix|club|dub|extended|edit|version|rework|bootleg|techno|workout|bpm)\b/i;

/** 0 = same title, 1 = same once a subtitle in brackets is dropped, 2 = different. */
function titleRank(wanted: string, track: string) {
  if (titleKey(track) === titleKey(wanted)) return 0;
  // A remix or other version only counts when the dance used that version.
  if (altVersion.test(titleKey(track)) && !altVersion.test(titleKey(wanted))) return 2;
  const core = titleCore(wanted) || titleKey(wanted);
  return titleCore(track) === core || titleKey(track) === core || titleCore(wanted) === titleKey(track) ? 1 : 2;
}

export function pickOriginal(results: ITunesTrack[], title: string, artist: string | null) {
  const scored = results
    .filter((track) => track.trackName && track.artistName && track.trackViewUrl
      && (!track.kind || track.kind === 'song')
      && !unwanted.test(track.trackName) && !unwanted.test(track.collectionName || ''))
    .map((track) => ({
      track,
      title: titleRank(title, track.trackName!),
      artist: artist ? artistRank(artist, track.artistName!) : 0,
      compiled: compilation.test(track.collectionName || '') || /various artists/i.test(track.collectionArtistName || '') ? 1 : 0,
      date: Date.parse(track.releaseDate || '') || Number.MAX_SAFE_INTEGER,
      album: track.collectionType === 'Album' ? 0 : 1,
    }))
    .filter((item) => item.title < 2 && item.artist < 2);
  // Exact title, then the artist on their own, then their own releases (compilations
  // often carry the wrong date), then the earliest release: the original recording.
  scored.sort((a, b) => a.title - b.title || a.artist - b.artist || a.compiled - b.compiled
    || a.date - b.date || a.album - b.album);
  return scored[0]?.track || null;
}

function cleanAppleUrl(raw: string) {
  const url = new URL(raw);
  url.searchParams.delete('uo');
  return url.toString();
}

async function searchITunes(title: string, artist: string | null) {
  const url = new URL('https://itunes.apple.com/search');
  url.searchParams.set('term', [title, artist ? primaryArtist(artist) : ''].join(' ').trim());
  url.searchParams.set('entity', 'song');
  url.searchParams.set('country', 'us');
  url.searchParams.set('limit', '25');
  const response = await fetch(url, { signal: AbortSignal.timeout(15000) });
  if (response.status === 429 || response.status === 403) throw new RateLimited('iTunes rate limit');
  if (!response.ok) throw new Error(`iTunes ${response.status}`);
  const body = await response.json();
  return (Array.isArray(body.results) ? body.results : []) as ITunesTrack[];
}

type SpotifyTrack = {
  name?: string; artists?: { name?: string }[];
  external_urls?: { spotify?: string };
  album?: { name?: string; album_type?: string; release_date?: string };
};

let spotifyToken: { value: string; expires: number } | null = null;

async function spotifyAccessToken() {
  if (!spotifyId || !spotifySecret) return null;
  if (spotifyToken && spotifyToken.expires > Date.now() + 30000) return spotifyToken.value;
  const response = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: { authorization: `Basic ${btoa(`${spotifyId}:${spotifySecret}`)}`,
      'content-type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error(`Spotify token ${response.status}`);
  const body = await response.json();
  spotifyToken = { value: body.access_token, expires: Date.now() + (body.expires_in || 3600) * 1000 };
  return spotifyToken.value;
}

/** The Spotify track for the same song: matching title and artist, earliest album release. */
async function spotifyFor(title: string, artist: string | null) {
  const token = await spotifyAccessToken();
  if (!token) return null;
  const url = new URL('https://api.spotify.com/v1/search');
  url.searchParams.set('q', artist ? `track:${title} artist:${primaryArtist(artist)}` : `track:${title}`);
  url.searchParams.set('type', 'track');
  url.searchParams.set('market', 'US');
  url.searchParams.set('limit', '20');
  const response = await fetch(url, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(15000) });
  if (response.status === 429) throw new RateLimited('Spotify rate limit');
  if (!response.ok) return null;
  const body = await response.json();
  const items = (body?.tracks?.items ?? []) as SpotifyTrack[];
  const wanted = titleKey(title);
  const candidates = items.filter((track) => track.name && track.external_urls?.spotify
    && !unwanted.test(track.name) && !unwanted.test(track.album?.name || '')
    && titleKey(track.name) === wanted
    && (!artist || (track.artists ?? []).some((credit) => credit.name && sameArtist(artist, credit.name))));
  const own = candidates.filter((track) => track.album?.album_type !== 'compilation' && !compilation.test(track.album?.name || ''));
  const pool = own.length ? own : candidates;
  pool.sort((a, b) => (a.album?.release_date || '9999').localeCompare(b.album?.release_date || '9999')
    || (a.album?.album_type === 'album' ? 0 : 1) - (b.album?.album_type === 'album' ? 0 : 1));
  const link = pool[0]?.external_urls?.spotify;
  return link && link.startsWith('https://open.spotify.com/track/') ? link.split('?')[0] : null;
}

async function matchOne(dance: Pending) {
  let track = await searchITunes(dance.song_title, dance.song_artist);
  let picked = pickOriginal(track, dance.song_title, dance.song_artist);
  if (!picked && /\(.*\)/.test(dance.song_title)) {
    // "Jenny from the Block (Track Masters Remix)": fall back to the plain title.
    const plain = dance.song_title.replace(/\s*\([^)]*\)\s*$/, '').trim();
    if (plain && plain !== dance.song_title) {
      track = await searchITunes(plain, dance.song_artist);
      picked = pickOriginal(track, plain, dance.song_artist);
    }
  }
  if (!picked?.trackViewUrl) {
    await rpc('record_dance_music_match_v2', {
      p_dance_id: dance.id, p_song_title: dance.song_title, p_song_artist: dance.song_artist,
      p_apple_url: null, p_spotify_url: null, p_status: 'no_match',
    });
    return { id: dance.id, title: dance.song_title, status: 'no_match' };
  }
  const apple = cleanAppleUrl(picked.trackViewUrl);
  const spotify = await spotifyFor(dance.song_title, dance.song_artist).catch((error) => {
    if (error instanceof RateLimited) throw error;
    console.error('spotify', dance.id, error);
    return null;
  });
  await rpc('record_dance_music_match_v2', {
    p_dance_id: dance.id, p_song_title: dance.song_title, p_song_artist: dance.song_artist,
    p_apple_url: apple, p_spotify_url: spotify, p_status: 'matched',
  });
  return { id: dance.id, title: dance.song_title, status: 'matched', apple, spotify,
    matched: `${picked.trackName} — ${picked.artistName} (${picked.collectionName}, ${picked.releaseDate?.slice(0, 10)})` };
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'POST required' }, 405);
  if (!supabaseUrl || !serviceKey) return json({ error: 'Matching is not configured' }, 503);
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token || (await rpc('music_match_authorized', { p_token: token }).catch(() => false)) !== true) {
    return json({ error: 'Unauthorized' }, 401);
  }
  try {
    const body = await request.json().catch(() => ({}));
    const danceId = typeof body?.dance_id === 'string' ? body.dance_id : null;
    const limit = Number.isInteger(body?.limit) ? body.limit : 8;
    const pending = (await rpc('pending_dance_music_matches', { p_limit: limit, p_dance_id: danceId })) as Pending[];
    const results = [];
    for (const dance of pending ?? []) {
      try {
        results.push(await matchOne(dance));
      } catch (error) {
        if (error instanceof RateLimited) {
          results.push({ id: dance.id, title: dance.song_title, status: 'rate_limited' });
          break;   // leave the rest pending for the next run
        }
        console.error(dance.id, error);
        results.push({ id: dance.id, title: dance.song_title, status: 'error',
          error: error instanceof Error ? error.message : String(error) });
      }
    }
    return json({ processed: results.length, results });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : 'Matching failed' }, 502);
  }
});
