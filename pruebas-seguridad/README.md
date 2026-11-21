# Carpeta de prueba — NO mergear

`codigo-vulnerable-de-prueba.js` contiene a propósito varios patrones de
vulnerabilidad clásicos (inyección de comandos, inyección SQL, hash
criptográfico débil, credenciales hardcodeadas, XSS reflejado y path
traversal). Es solo para confirmar que Jenkins (Semgrep y gitleaks) los
detecta de punta a punta.

No lo usa ni lo importa ningún otro archivo del proyecto, y no lo
compila TypeScript ni lo corre Jest. Este PR es de prueba: se cierra sin
mergear una vez confirmado que Jenkins reaccionó.
