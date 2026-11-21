import "./env.setup";
import { cifrar, descifrar } from "../src/utils/cripto2fa";

describe("Cifrado del secreto TOTP (src/utils/cripto2fa.ts)", () => {
  it("cifrar + descifrar devuelve el texto original (round-trip con el tag de autenticación GCM explícito)", () => {
    const original = "SECRETO-TOTP-DE-PRUEBA-123456";
    const cifrado = cifrar(original);

    // El valor cifrado nunca debe contener el texto en plano.
    expect(cifrado).not.toContain(original);

    const descifrado = descifrar(cifrado);
    expect(descifrado).toBe(original);
  });

  it("descifrar rechaza un valor manipulado (el tag de autenticación GCM detecta la alteración)", () => {
    const cifrado = cifrar("otro-secreto-totp");
    const datos = Buffer.from(cifrado, "base64");
    // Se altera un byte del texto cifrado (después de iv + tag) para
    // simular una manipulación; GCM debe detectarlo y lanzar al descifrar.
    datos[datos.length - 1] ^= 0xff;
    const manipulado = datos.toString("base64");

    expect(() => descifrar(manipulado)).toThrow();
  });
});
