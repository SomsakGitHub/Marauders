/**
 * Runs `work` up to `attempts` times, waiting `pauseMs` between tries, and rethrows the last error when every try failed.
 * For calls that are safe to repeat (a delete of the same key, a list of the same prefix).
 */
export async function withAttempts<T>(
  work: () => Promise<T>,
  attempts: number = 3,
  pauseMs: number = 150,
): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await work();
    } catch (error) {
      lastError = error;
      if (attempt < attempts && pauseMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, pauseMs));
      }
    }
  }
  throw lastError;
}
