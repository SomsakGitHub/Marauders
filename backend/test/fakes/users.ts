// In-memory stand-in for src/db/users, swapped in by scripts/test-dev-auth.mjs so no database is ever contacted.

export const upsertCalls: Array<{
  databaseUrl: string;
  appleSub: string;
  country: string | null;
}> = [];

const idsByAppleSub = new Map<string, string>();
let failWith: Error | null = null;

export function resetFakeUsers(): void {
  upsertCalls.length = 0;
  idsByAppleSub.clear();
  failWith = null;
}

export function failNextUpserts(error: Error | null): void {
  failWith = error;
}

export async function upsertUserByAppleSub(
  databaseUrl: string,
  appleSub: string,
  country: string | null = null,
): Promise<string> {
  upsertCalls.push({ databaseUrl, appleSub, country });
  if (failWith) {
    throw failWith;
  }
  let id = idsByAppleSub.get(appleSub);
  if (!id) {
    id = `00000000-0000-4000-8000-${String(idsByAppleSub.size + 1).padStart(12, "0")}`;
    idsByAppleSub.set(appleSub, id);
  }
  return id;
}
