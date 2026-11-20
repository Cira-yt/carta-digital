import request from "supertest";
import { createApp } from "../src/app";
import { pool } from "../src/config/db";

const app = createApp();

describe("Cabeceras de seguridad HTTP (OWASP A05 — Security Misconfiguration)", () => {
  afterAll(async () => {
    await pool.end();
  });

  it("GET /health responde con las cabeceras de helmet (CSP, X-Frame-Options, X-Content-Type-Options)", async () => {
    const res = await request(app).get("/health");

    expect(res.status).toBe(200);

    // Si alguien borra `app.use(securityHeaders)` en app.ts por error, este
    // test falla y el check de Jenkins queda en rojo (antes, nada lo detectaba).
    expect(res.headers["content-security-policy"]).toBeDefined();
    expect(res.headers["content-security-policy"]).toContain("default-src 'self'");
    expect(res.headers["content-security-policy"]).toContain("frame-ancestors 'none'");

    expect(res.headers["x-frame-options"]).toBe("SAMEORIGIN");
    expect(res.headers["x-content-type-options"]).toBe("nosniff");
  });

  it("no revela la tecnología del servidor (X-Powered-By ausente)", async () => {
    const res = await request(app).get("/health");
    expect(res.headers["x-powered-by"]).toBeUndefined();
  });

  it("no fuerza HSTS desde el origen (el servidor solo escucha HTTP; TLS se termina en el borde)", async () => {
    const res = await request(app).get("/health");
    expect(res.headers["strict-transport-security"]).toBeUndefined();
  });
});
