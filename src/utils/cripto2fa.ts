import crypto from "crypto";
import { env } from "../config/env";

/**
 * Cifra en reposo el secreto TOTP del 2FA (OWASP A02 - Cryptographic
 * Failures): aunque es un dato "solo nuestro" y no una contraseña, si la
 * base de datos se filtrara, un secreto TOTP en texto plano permitiría
 * generar códigos válidos indefinidamente. Se cifra con AES-256-GCM usando
 * una clave derivada de SESSION_SECRET (ya es un secreto largo y aleatorio
 * requerido por la app — ver config/env.ts).
 */
const CLAVE = crypto.createHash("sha256").update(env.session.secret).digest();

// 16 bytes (128 bits) es el largo estandar del tag de autenticacion GCM, y
// ya es lo que usamos (ver TAMANO_TAG mas abajo). Se lo pasamos explicito a
// create[De]Cipheriv (en vez de dejarlo implicito) por lo mismo que pide
// Semgrep (regla gcm-no-tag-length, OWASP A02): si no se fija, en teoria se
// podria terminar aceptando un tag mas corto de lo esperado al descifrar,
// debilitando la autenticacion del cifrado.
const TAMANO_TAG = 16;

export function cifrar(texto: string): string {
  const iv = crypto.randomBytes(12);
  const cifrador = crypto.createCipheriv("aes-256-gcm", CLAVE, iv, { authTagLength: TAMANO_TAG });
  const cifrado = Buffer.concat([cifrador.update(texto, "utf8"), cifrador.final()]);
  const tag = cifrador.getAuthTag();
  return Buffer.concat([iv, tag, cifrado]).toString("base64");
}

export function descifrar(valor: string): string {
  const datos = Buffer.from(valor, "base64");
  const iv = datos.subarray(0, 12);
  const tag = datos.subarray(12, 12 + TAMANO_TAG);
  const cifrado = datos.subarray(12 + TAMANO_TAG);
  const descifrador = crypto.createDecipheriv("aes-256-gcm", CLAVE, iv, { authTagLength: TAMANO_TAG });
  descifrador.setAuthTag(tag);
  return Buffer.concat([descifrador.update(cifrado), descifrador.final()]).toString("utf8");
}
