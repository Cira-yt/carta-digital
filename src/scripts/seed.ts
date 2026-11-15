/**
 * Siembra los usuarios de prueba con contraseña hasheada (bcrypt).
 * Uso: npm run seed
 *
 * Las contraseñas NO se hardcodean (este repo es público): se toman de
 * SEED_ADMIN_PASSWORD / SEED_CLIENTE_PASSWORD, o se generan al azar y se
 * imprimen una sola vez en la consola si no definís esas variables.
 */
import bcrypt from "bcryptjs";
import crypto from "crypto";
import { pool } from "../config/db";
import { crearUsuario } from "../models/usuarioModel";

function contraseñaAleatoria(): string {
  return crypto.randomBytes(9).toString("base64url"); // ej. "k3f9Qz2n_X1pR0a"
}

const passAdmin = process.env.SEED_ADMIN_PASSWORD ?? contraseñaAleatoria();
const passCliente = process.env.SEED_CLIENTE_PASSWORD ?? contraseñaAleatoria();

const USUARIOS: { nombre: string; email: string; password: string; rol: "admin" | "cliente" }[] = [
  { nombre: "Administrador", email: "admin@gmail.com", password: passAdmin, rol: "admin" },
  { nombre: "Alondra", email: "alondra@gmail.com", password: passCliente, rol: "cliente" },
];

async function main(): Promise<void> {
  for (const u of USUARIOS) {
    const hash = await bcrypt.hash(u.password, 12);
    await crearUsuario(u.nombre, u.email, hash, u.rol);
    const origen = process.env[`SEED_${u.rol.toUpperCase()}_PASSWORD`] ? "" : ` (contraseña generada: ${u.password})`;
    console.log(`Usuario sembrado: ${u.email} (rol: ${u.rol})${origen}`);
  }
  await pool.end();
  console.log("Seed completado. Guarda las contraseñas generadas arriba: no se vuelven a mostrar.");
}

main().catch((err) => {
  console.error("Error al sembrar usuarios:", err);
  process.exit(1);
});
