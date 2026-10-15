// Only confirmed or manually assigned database matches may become player URLs.
export function youtubeVideoFor({ youtube_video_id: id, youtube_match_status: status, youtube_title: title } = {}) {
  if (!['matched', 'manual'].includes(status) || typeof id !== 'string' || !/^[A-Za-z0-9_-]{11}$/.test(id)) return null;
  return {
    id,
    title: typeof title === 'string' ? title : '',
    embedUrl: `https://www.youtube.com/embed/${id}?playsinline=1&rel=0`,
    watchUrl: `https://www.youtube.com/watch?v=${id}`,
  };
}
