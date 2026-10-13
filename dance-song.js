// Read the database's separate fields, never parse or fall back to dances.song.
export function danceSongParts(dance = {}) {
  return {
    title: String(dance?.song_title ?? '').trim(),
    artist: String(dance?.song_artist ?? '').trim(),
  };
}

export function danceSongLabel(dance) {
  const { entries, artists, medley } = danceSongList(dance);
  if (medley) {
    const songs = entries.map(({ title, artist }) => title ? joinDanceSong(title, artist) : artist).join(' · ');
    return `${songs}${artists.length ? ` · Artists: ${artists.join(' / ')}` : ''}`;
  }
  const { title, artist } = danceSongParts(dance);
  return title ? joinDanceSong(title, artist) : artist;
}

// Keep empty positions while pairing so a missing artist cannot shift later credits.
// Unequal lists remain separate; never infer which artist belongs to which song.
export function danceSongList(dance) {
  const { title, artist } = danceSongParts(dance);
  const titles = title.split(';').map((value) => value.trim());
  const artists = artist.split(';').map((value) => value.trim());
  const medley = titles.filter(Boolean).length > 1;
  const paired = titles.length === artists.length;
  return {
    medley,
    entries: titles.map((value, index) => ({ title: value, artist: paired ? artists[index] : '' }))
      .filter((entry) => entry.title || entry.artist),
    artists: paired ? [] : artists.filter(Boolean),
  };
}

// Presentation formatting only. Save title/artist separately via the new API.
export function joinDanceSong(title, artist) {
  const cleanTitle = String(title || '').trim();
  const cleanArtist = String(artist || '').trim();
  return cleanTitle ? `${cleanTitle}${cleanArtist ? ` by ${cleanArtist}` : ''}` : '';
}
