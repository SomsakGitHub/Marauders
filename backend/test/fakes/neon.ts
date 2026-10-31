// Programmable stand-in for @neondatabase/serverless, swapped in by scripts/test-comments.mjs so no database is ever contacted.

export type Query = { text: string; values: unknown[] };

export const queries: Query[] = [];

type Responder = (query: Query) => unknown[];

let responder: Responder = () => [];

export function resetFakeNeon(): void {
  queries.length = 0;
  responder = () => [];
}

/** Decides the rows each query returns; throw from it to make that query fail. */
export function respondWith(next: Responder): void {
  responder = next;
}

export function neon(_databaseUrl: string) {
  return async (strings: TemplateStringsArray, ...values: unknown[]): Promise<unknown[]> => {
    const query = { text: strings.join("?"), values };
    queries.push(query);
    return responder(query);
  };
}
