import request from "supertest";
import { createApp } from "../src/app";
import { pool } from "../src/config/db";
import { csrfDeMeta, csrfDeApi } from "./helpers";

const app = createApp();

// Mismo helper que en admin.test.ts: el login sigue siendo la API JSON que
// consume el frontend React, el panel admin (EJS) que viene después no cambia.
async function loginAdmin(agent: ReturnType<typeof request.agent>): Promise<void> {
  const csrf = await csrfDeApi(agent);
  await agent.post("/api/login").set("X-CSRF-Token", csrf).send({ email: "admin@test.local", password: "TestPass#2026!" });
}

/** Crea un pedido real para el restaurante del itemId dado, vía el carrito público, y devuelve su id. */
async function crearPedido(itemId: number): Promise<number> {
  const agente = request.agent(app);
  const csrf = await csrfDeApi(agente);
  await agente.post("/api/carrito/agregar").set("X-CSRF-Token", csrf).send({ itemId });
  const confirmar = await agente.post("/api/carrito/confirmar").set("X-CSRF-Token", csrf);
  return (confirmar.body.pedidos as { id: number }[])[0].id;
}

async function estadoDe(pedidoId: number): Promise<string> {
  const { rows } = await pool.query("SELECT estado FROM pedidos WHERE id = $1", [pedidoId]);
  return rows[0].estado;
}

describe("Ventas — cambio de estado de pedidos (IDOR)", () => {
  afterAll(async () => {
    await pool.end();
  });

  it("el admin puede cambiar el estado de un pedido de SU restaurante activo", async () => {
    // Ítem 1 (Ensalada Cesar) es del restaurante 1.
    const pedidoId = await crearPedido(1);
    expect(await estadoDe(pedidoId)).toBe("confirmado");

    const agent = request.agent(app);
    await loginAdmin(agent);
    await agent.get("/admin/1"); // activa el restaurante 1 en sesión

    const ventas = await agent.get("/admin/ventas");
    const csrf = csrfDeMeta(ventas.text);

    const res = await agent
      .post(`/admin/pedidos/${pedidoId}/estado`)
      .type("form")
      .send({ estado: "entregado", csrfToken: csrf });
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe("/admin/ventas");

    expect(await estadoDe(pedidoId)).toBe("entregado");
  });

  it("el admin NO puede cambiar el estado de un pedido de OTRO restaurante (IDOR)", async () => {
    // Ítem 1 (Ensalada Cesar) es del restaurante 1; el admin de abajo tiene
    // activo el restaurante 2, así que este pedido es "de otro restaurante".
    const pedidoId = await crearPedido(1);
    expect(await estadoDe(pedidoId)).toBe("confirmado");

    const agent = request.agent(app);
    await loginAdmin(agent);
    await agent.get("/admin/2"); // activa el restaurante 2 en sesión (no el 1)

    const ventas = await agent.get("/admin/ventas");
    const csrf = csrfDeMeta(ventas.text);

    const res = await agent
      .post(`/admin/pedidos/${pedidoId}/estado`)
      .type("form")
      .send({ estado: "entregado", csrfToken: csrf });
    // La ruta siempre redirige (no delata si el pedido existe o no),
    // pero el UPDATE real no afecta ninguna fila por el filtro de restaurante.
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe("/admin/ventas");

    expect(await estadoDe(pedidoId)).toBe("confirmado");
  });
});
