export function parseLimit(value: unknown): number | undefined {
  if (value === undefined) return 100;
  if (typeof value !== "string" || !/^\d+$/.test(value)) return undefined;
  const limit = Number(value);
  return Number.isSafeInteger(limit) && limit >= 1 && limit <= 1000
    ? limit
    : undefined;
}
