import type { Pool } from "pg";

export type OrderMode = "lento" | "otimizado";
export interface Order {
  id: number;
  client_id: number;
  description: string;
  amount: string;
  created_at: string;
  client: { id: number; name: string };
}
interface OrderRow {
  id: number;
  client_id: number;
  description: string;
  amount: string;
  created_at: Date;
}
interface ClientRow {
  id: number;
  name: string;
}

function serialize(order: OrderRow, client: ClientRow): Order {
  return {
    id: order.id,
    client_id: order.client_id,
    description: order.description,
    amount: order.amount,
    created_at: order.created_at.toISOString(),
    client: { id: client.id, name: client.name },
  };
}

export function createOrdersRepository(pool: Pick<Pool, "query">) {
  return async function list(mode: OrderMode, limit: number): Promise<Order[]> {
    if (mode === "otimizado") {
      const result = await pool.query<
        OrderRow & { joined_client_id: number; name: string }
      >(
        `SELECT o.id, o.client_id, o.description, o.amount, o.created_at,
                c.id AS joined_client_id, c.name
         FROM orders o INNER JOIN clients c ON c.id = o.client_id
         ORDER BY o.id ASC LIMIT $1`,
        [limit],
      );
      return result.rows.map((row) =>
        serialize(row, { id: row.joined_client_id, name: row.name }),
      );
    }
    const result = await pool.query<OrderRow>(
      "SELECT id, client_id, description, amount, created_at FROM orders ORDER BY id ASC LIMIT $1",
      [limit],
    );
    const orders: Order[] = [];
    for (const row of result.rows) {
      const clients = await pool.query<ClientRow>(
        "SELECT id, name FROM clients WHERE id = $1",
        [row.client_id],
      );
      const client = clients.rows[0];
      if (!client) throw new Error("Cliente do pedido não encontrado.");
      orders.push(serialize(row, client));
    }
    return orders;
  };
}
