/**
 * Dates in frontmatter are parsed as UTC midnight, so format in UTC too —
 * otherwise a negative timezone offset renders the previous day.
 */
export function formatDate(date: Date): string {
  return date.toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC',
  });
}

/** ISO date (YYYY-MM-DD) for <time datetime="…">. */
export function isoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

const WORDS_PER_MINUTE = 200;

export function readingTime(body: string | undefined): string {
  const words = (body ?? '').trim().split(/\s+/).filter(Boolean).length;
  return `${Math.max(1, Math.round(words / WORDS_PER_MINUTE))} min read`;
}
