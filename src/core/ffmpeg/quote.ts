/** Mirror of FFmpegCommandRunner.quoted — single-quote with escaped interior quotes. */
export function quoteFFmpegPath(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}
