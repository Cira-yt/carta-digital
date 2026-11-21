// Lee reporte-dependencias/dependency-check-report.json (generado por la
// etapa "OWASP Dependency-Check" del Jenkinsfile) y escribe en stdout un
// resumen de una sola línea: "<total>|<severidad: cantidad, ...>".
//
// El Jenkinsfile inserta esa línea en el cuerpo del email que manda al
// final del pipeline, para que se pueda ver de un vistazo si hay algo
// grave sin tener que abrir el reporte HTML adjunto.
const fs = require("fs");

const RUTA_REPORTE = "reporte-dependencias/dependency-check-report.json";

function main() {
  if (!fs.existsSync(RUTA_REPORTE)) {
    console.log("0|el reporte no se generó");
    return;
  }

  const datos = JSON.parse(fs.readFileSync(RUTA_REPORTE, "utf8"));
  const vulnerabilidades = (datos.dependencies || []).flatMap(
    (dependencia) => dependencia.vulnerabilities || []
  );

  const porSeveridad = {};
  for (const vulnerabilidad of vulnerabilidades) {
    const severidad = (vulnerabilidad.severity || "DESCONOCIDA").toUpperCase();
    porSeveridad[severidad] = (porSeveridad[severidad] || 0) + 1;
  }

  const detalle =
    Object.entries(porSeveridad)
      .map(([severidad, cantidad]) => `${severidad}: ${cantidad}`)
      .join(", ") || "ninguna";

  console.log(`${vulnerabilidades.length}|${detalle}`);
}

main();
