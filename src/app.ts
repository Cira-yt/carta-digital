import express, { Express } from "express";
import path from "path";
import { sessionMiddleware } from "./middlewares/session";
import { securityHeaders } from "./middlewares/security";
import { csrfToken } from "./middlewares/csrf";
import { errorHandler, notFoundHandler } from "./middlewares/errorHandler";
import { router } from "./routes";
import { adminRouter } from "./routes/admin";
import { S3_FOTOS_BUCKET } from "./middlewares/upload";

export function createApp(): Express {
  const app = express();

  // Detrás del ALB (y Cloudflare delante de este), el primer salto hacia la
  // app es siempre el ALB: confiamos en 1 proxy para que Express tome la IP
  // real del cliente desde X-Forwarded-For en vez de la IP interna del ALB.
  // Sin esto, el rate-limit de login (middlewares/rateLimiter.ts) y el log
  // de seguridad (utils/logSeguridad.ts) agrupan a TODOS los usuarios bajo
  // la misma IP aparente, bloqueando a todos tras solo 5 intentos de
  // cualquiera. Antes era un riesgo aceptado documentado en el informe OWASP
  // (A05, "Security Misconfiguration"); queda resuelto con esta línea.
  app.set("trust proxy", 1);

  app.disable("x-powered-by"); // no filtrar la tecnología/versión del servidor

  app.set("view engine", "ejs");
  app.set("views", path.join(__dirname, "views"));

  app.use(securityHeaders);
  app.use(express.urlencoded({ extended: false }));
  app.use(express.json());
  app.use(sessionMiddleware);
  app.use(csrfToken);

  app.use(express.static(path.join(__dirname, "public")));
  // Assets de la SPA de React (JS/CSS con hash, ver frontend/vite.config.ts).
  app.use(express.static(path.join(__dirname, "public-spa")));

  // Fotos de platos/restaurantes subidas desde el panel de administración:
  // viven en S3, no en el disco de la instancia (ver middlewares/upload.ts).
  // Las fotos de ejemplo que sí vienen con el repo (src/public/imagenes/...)
  // ya las sirvió el express.static de arriba; esto es el fallback para las
  // que no están en disco porque se subieron después, por un admin: mismo
  // URL de siempre (/imagenes/cod{id}/{archivo}), redirigido al objeto real
  // en S3, para no tener que tocar las vistas ni el frontend.
  app.get("/imagenes/:carpeta/:archivo", (req, res, next) => {
    const { carpeta, archivo } = req.params;
    if (!S3_FOTOS_BUCKET || !/^cod\d+$/.test(carpeta) || archivo.includes("/") || archivo.includes("..")) {
      next();
      return;
    }
    const region = process.env.AWS_REGION || "us-east-1";
    res.redirect(
      302,
      `https://${S3_FOTOS_BUCKET}.s3.${region}.amazonaws.com/${carpeta}/${encodeURIComponent(archivo)}`
    );
  });

  // Usado por Docker/Jenkins para verificar que la app está viva.
  app.get("/health", (_req, res) => res.status(200).json({ ok: true }));

  app.use("/admin", adminRouter);
  app.use("/api", router);

  // Fallback de la SPA: cualquier otra ruta GET (/, /africarestobar, /carrito,
  // etc.) sirve el index.html de React, que resuelve la ruta en el cliente
  // (react-router) y pide los datos a /api/*.
  app.get("*", (_req, res) => {
    res.sendFile(path.join(__dirname, "public-spa", "index.html"));
  });

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
