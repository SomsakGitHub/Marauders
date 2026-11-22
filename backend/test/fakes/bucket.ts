// In-memory stand-in for the parts of an R2 bucket that the account deletion code calls, so no test reaches the real bucket.
// It behaves like R2 where the code depends on it: a list is sorted, paged by `pageSize` and continued with a cursor that
// names the last key already returned (so deleting a page does not disturb the next one), and one delete takes at most
// 1,000 keys. A test makes a call fail with `failNext`.

export const MAX_KEYS_PER_DELETE = 1000;

/** UTF-16 code unit order, the order `>` uses in `list`, so the sort and the cursor ("keys after this one") agree. */
function byKey(a: string, b: string): number {
  if (a === b) return 0;
  return a < b ? -1 : 1;
}

export class FakeBucket {
  /** key -> body; the code under test only ever looks at keys. */
  objects = new Map<string, string>();
  /** How many keys one list call returns. */
  pageSize = 1000;
  /** Every call that reached the bucket, in order, failed ones included. */
  calls: Array<{ op: string; arg: unknown }> = [];

  private failures = { list: 0, delete: 0 };

  /** The next `times` calls of `op` throw; the call after that works again. */
  failNext(op: "list" | "delete", times: number): void {
    this.failures[op] = times;
  }

  async list(
    options: { prefix?: string; cursor?: string } = {},
  ): Promise<{ objects: { key: string }[]; truncated: boolean; cursor?: string }> {
    this.calls.push({ op: "list", arg: options });
    this.throwIfFailing("list");
    const after = options.cursor?.startsWith("after:") ? options.cursor.slice("after:".length) : undefined;
    const keys = [...this.objects.keys()]
      .filter((key) => key.startsWith(options.prefix ?? ""))
      .sort(byKey)
      .filter((key) => after === undefined || key > after);
    const page = keys.slice(0, this.pageSize);
    const truncated = keys.length > page.length;
    return {
      objects: page.map((key) => ({ key })),
      truncated,
      cursor: truncated ? `after:${page[page.length - 1]}` : undefined,
    };
  }

  async delete(keys: string | string[]): Promise<void> {
    this.calls.push({ op: "delete", arg: keys });
    this.throwIfFailing("delete");
    const list = Array.isArray(keys) ? keys : [keys];
    if (list.length > MAX_KEYS_PER_DELETE) {
      throw new Error(`R2 deletes at most ${MAX_KEYS_PER_DELETE} keys in one call, got ${list.length}`);
    }
    for (const key of list) {
      this.objects.delete(key);
    }
  }

  private throwIfFailing(op: "list" | "delete"): void {
    if (this.failures[op] > 0) {
      this.failures[op] -= 1;
      throw new Error(`${op} failed (fake)`);
    }
  }
}
