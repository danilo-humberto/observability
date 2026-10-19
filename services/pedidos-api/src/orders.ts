export type OrderMode = "lento" | "otimizado";
export interface Order {
  id: number;
  client_id: number;
  description: string;
  amount: string;
  created_at: string;
  client: { id: number; name: string };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function isId(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 1 &&
    value <= 2147483647
  );
}
export function isOrders(value: unknown, limit: number): value is Order[] {
  if (!Array.isArray(value) || value.length > limit) return false;
  let previous = 0;
  for (const row of value) {
    if (
      !isRecord(row) ||
      !isId(row.id) ||
      row.id <= previous ||
      !isId(row.client_id) ||
      typeof row.description !== "string" ||
      typeof row.amount !== "string" ||
      !/^\d{1,10}\.\d{2}$/.test(row.amount) ||
      typeof row.created_at !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(row.created_at) ||
      !Number.isFinite(Date.parse(row.created_at)) ||
      new Date(row.created_at).toISOString() !== row.created_at ||
      !isRecord(row.client) ||
      !isId(row.client.id) ||
      row.client.id !== row.client_id ||
      typeof row.client.name !== "string" ||
      Object.keys(row).sort().join(",") !==
        "amount,client,client_id,created_at,description,id" ||
      Object.keys(row.client).sort().join(",") !== "id,name"
    )
      return false;
    previous = row.id;
  }
  return true;
}
