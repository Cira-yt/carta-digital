import multer from "multer";
import crypto from "crypto";
import path from "path";
import { Request } from "express";
import { S3Client, DeleteObjectCommand } from "@aws-sdk/client-s3";
import { Upload } from "@aws-sdk/lib-storage";
import { idValido } from "../utils/validar";

/**
 * Subida de la foto de un producto. Reglas de seguridad:
 *  - Solo se aceptan imágenes (whitelist de MIME type Y de extensión; el MIME
 *    que manda el navegador no es confiable por sí solo, así que se exige
 *    que ambos coincidan).
 *  - Tamaño máximo 5 MB.
 *  - El nombre de archivo NUNCA usa el nombre original (evita path
 *    traversal / sobrescritura): se genera uno aleatorio con crypto.
 *  - Las imágenes se guardan en un bucket S3, bajo la key cod{restauranteId}/,
 *    siguiendo la misma convención de carpetas que usaba el disco local.
 *
 * Por qué S3 y no el disco de la instancia: la app corre en un Auto Scaling
 * Group con más de una instancia EC2 detrás del Load Balancer (ver
 * deploy.env.example, ASG_DESIRED). Si la foto quedara en el disco de una
 * sola instancia, ni siquiera sería visible de forma consistente entre
 * pedidos (el ALB reparte el tráfico entre instancias), y además se perdería
 * por completo si esa instancia se reemplaza (redeploy, instance refresh, o
 * "desplegar.sh destruir" + volver a levantar). El bucket S3 es un recurso
 * aparte, independiente del ciclo de vida de las instancias: no lo borra
 * "desplegar.sh destruir" ni "destruir-todo" (ver ese script).
 */
const TIPOS_PERMITIDOS: Record<string, string> = {
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/webp": ".webp",
  "image/gif": ".gif",
};

export const S3_FOTOS_BUCKET = process.env.S3_FOTOS_BUCKET || "";
const AWS_REGION = process.env.AWS_REGION || "us-east-1";

// Un solo cliente S3 para todo el proceso (el SDK reutiliza conexiones).
// Las credenciales las toma del rol de instancia de EC2 (instance profile),
// nunca de variables de entorno con claves: ver IAM_INSTANCE_PROFILE en
// scripts/deploy/desplegar.sh.
const s3 = new S3Client({ region: AWS_REGION });

export function carpetaImagenes(restauranteId: number): string {
  return `cod${restauranteId}`;
}

function keyImagen(restauranteId: number, nombreArchivo: string): string {
  return `${carpetaImagenes(restauranteId)}/${nombreArchivo}`;
}

function restauranteIdDesdeSesion(req: Request): number {
  return idValido(req.session.restauranteId) ?? 1;
}

function restauranteIdDesdeParams(req: Request): number {
  const id = idValido(req.params.id);
  if (id === null) throw new Error("id de restaurante inválido");
  return id;
}

/**
 * Borra una foto de producto del bucket S3 (p. ej. la anterior, al
 * reemplazarla o al eliminar el producto). Nunca lanza error si el archivo
 * no existe: borrar un objeto que no está ya es un no-op en S3.
 */
export function borrarFoto(restauranteId: number, nombreArchivo: string | null | undefined): void {
  if (!nombreArchivo) return;
  // Blindaje extra: solo se borra un nombre de archivo plano (el que generamos
  // nosotros mismos), nunca algo con rutas ("../", "/", etc.).
  if (nombreArchivo.includes("/") || nombreArchivo.includes("\\") || nombreArchivo.includes("..")) return;
  if (!S3_FOTOS_BUCKET) return;
  s3.send(
    new DeleteObjectCommand({ Bucket: S3_FOTOS_BUCKET, Key: keyImagen(restauranteId, nombreArchivo) })
  ).catch(() => {
    /* si falla, no es crítico: no queremos romper el flujo de borrado del producto por esto */
  });
}

const filtroImagen: multer.Options["fileFilter"] = (_req, file, cb) => {
  const extOk = Object.values(TIPOS_PERMITIDOS).includes(
    path.extname(file.originalname).toLowerCase()
  );
  const mimeOk = Object.prototype.hasOwnProperty.call(TIPOS_PERMITIDOS, file.mimetype);
  if (extOk && mimeOk) {
    cb(null, true);
  } else {
    cb(new Error("Solo se permiten imágenes JPG, PNG, WEBP o GIF."));
  }
};

/**
 * Motor de almacenamiento de multer que sube el archivo a S3 en vez de
 * escribirlo en disco. Devuelve "filename" igual que multer.diskStorage, así
 * que los controladores (req.file.filename) no necesitan cambiar.
 */
class AlmacenamientoS3 implements multer.StorageEngine {
  constructor(private restauranteIdDe: (req: Request) => number) {}

  _handleFile(
    req: Request,
    file: Express.Multer.File,
    cb: (error?: unknown, info?: Partial<Express.Multer.File>) => void
  ): void {
    let restauranteId: number;
    try {
      restauranteId = this.restauranteIdDe(req);
    } catch (err) {
      cb(err);
      return;
    }
    if (!S3_FOTOS_BUCKET) {
      cb(new Error("S3_FOTOS_BUCKET no está configurado: no se puede subir la foto."));
      return;
    }
    const ext = TIPOS_PERMITIDOS[file.mimetype] ?? "";
    const nombreAleatorio = crypto.randomBytes(16).toString("hex");
    const filename = `${nombreAleatorio}${ext}`;
    const key = keyImagen(restauranteId, filename);

    const subida = new Upload({
      client: s3,
      params: {
        Bucket: S3_FOTOS_BUCKET,
        Key: key,
        Body: file.stream,
        ContentType: file.mimetype,
      },
    });

    subida
      .done()
      .then(() => cb(null, { filename, destination: S3_FOTOS_BUCKET, path: key }))
      .catch((err) => cb(err));
  }

  _removeFile(_req: Request, file: Express.Multer.File, cb: (error: Error | null) => void): void {
    const key = (file as Express.Multer.File & { path?: string }).path;
    if (!key || !S3_FOTOS_BUCKET) {
      cb(null);
      return;
    }
    s3.send(new DeleteObjectCommand({ Bucket: S3_FOTOS_BUCKET, Key: key }))
      .then(() => cb(null))
      .catch(() => cb(null));
  }
}

export const uploadFoto = multer({
  storage: new AlmacenamientoS3(restauranteIdDesdeSesion),
  limits: { fileSize: 5 * 1024 * 1024, files: 1 }, // 5 MB
  fileFilter: filtroImagen,
}).single("foto");

/**
 * Foto del restaurante (logo): se guarda bajo la MISMA key cod{id} que sus
 * productos, usando el :id de la URL (no la sesión) — el edit siempre trae
 * el id del restaurante que se está editando.
 */
export const uploadFotoRestaurante = multer({
  storage: new AlmacenamientoS3(restauranteIdDesdeParams),
  limits: { fileSize: 5 * 1024 * 1024, files: 1 },
  fileFilter: filtroImagen,
}).single("foto");
