/*
 * PRUEBA DE SEGURIDAD — código deliberadamente vulnerable.
 *
 * Este archivo NO forma parte de la aplicación: no está en src/, no lo
 * compila TypeScript (tsconfig solo incluye src/**\/*.ts) y no lo corre
 * Jest (jest.config solo corre tests/**\/*.test.ts). No lo importa nada.
 * Su único propósito es contener varios patrones de vulnerabilidad
 * clásicos (OWASP Top 10) a propósito, para confirmar que Jenkins los
 * detecta de punta a punta: Semgrep (p/owasp-top-ten) y gitleaks.
 *
 * Las credenciales de abajo son las claves de EJEMPLO públicas que la
 * propia documentación de AWS usa (AKIAIOSFODNN7EXAMPLE / wJalr...), no
 * son reales — sirven para que gitleaks las reconozca por su formato.
 *
 * Este PR es solo de prueba: no se va a mergear.
 */

const { exec } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

// 1) Inyección de comandos (OWASP A03 - Injection): el input del usuario
//    se concatena directo en un comando de shell.
function listarArchivosDeUsuario(nombreCarpeta, callback) {
  exec("ls -la " + nombreCarpeta, (err, stdout) => callback(err, stdout));
}

// 2) Inyección SQL (OWASP A03 - Injection): la query se arma concatenando
//    strings en vez de usar parámetros preparados.
function buscarUsuarioPorNombre(db, nombreIngresado) {
  const query = "SELECT * FROM usuarios WHERE nombre = '" + nombreIngresado + "'";
  return db.query(query);
}

// 3) Algoritmo criptográfico débil (OWASP A02 - Cryptographic Failures):
//    MD5 no es apto para contraseñas ni para nada sensible.
function hashDeContrasenaInseguro(contrasena) {
  return crypto.createHash("md5").update(contrasena).digest("hex");
}

// 4) Credenciales hardcodeadas (OWASP A07 / secretos filtrados) — valores
//    de EJEMPLO oficiales de AWS, no son una cuenta real.
const AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE";
const AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";

// 5) Cross-Site Scripting reflejado (OWASP A03 - Injection / XSS): se
//    devuelve el input del usuario sin escapar dentro de HTML.
function responderConSaludoInseguro(req, res) {
  const nombre = req.query.nombre;
  res.send("<div>Hola " + nombre + "</div>");
}

// 6) Path Traversal (OWASP A01 - Broken Access Control): se arma la ruta
//    de archivo con el input del usuario sin validar "..".
function leerArchivoDeUsuario(nombreArchivo) {
  const rutaCompleta = path.join(__dirname, "uploads", nombreArchivo);
  return fs.readFileSync(rutaCompleta, "utf8");
}

module.exports = {
  listarArchivosDeUsuario,
  buscarUsuarioPorNombre,
  hashDeContrasenaInseguro,
  responderConSaludoInseguro,
  leerArchivoDeUsuario,
};
