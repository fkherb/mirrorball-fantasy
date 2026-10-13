// Read the database's separate fields, never parse or fall back to dances.song.
export function danceSongParts(dance = {}) {
  return {
    title: String(dance?.song_title ?? '').trim(),
    artist: String(dance?.song_artist ?? '').trim(),
  };
}

export function danceSongLabel(dance) {
  const { title, artist } = danceSongParts(dance);
  return title ? joinDanceSong(title, artist) : artist;
}

// Formatting only. The current save_dance_atomic RPC still accepts p_song;
// its database trigger fills song_title/song_artist and refreshes music matches.
export function joinDanceSong(title, artist) {
  const cleanTitle = String(title || '').trim();
  const cleanArtist = String(artist || '').trim();
  return cleanTitle ? `${cleanTitle}${cleanArtist ? ` by ${cleanArtist}` : ''}` : '';
}
