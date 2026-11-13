/**
 * Dotted date, e.g. 2026.11.13. Frontmatter dates are parsed as UTC midnight,
 * so read the UTC fields — a negative timezone offset would show the previous day.
 */
export function formatDate(date: Date): string {
  return date.toISOString().slice(0, 10).replaceAll('-', '.');
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
