import { FormEvent, useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { api, CartaCompleta, Item } from "../api";
import { fotoUrl, formatearCLP } from "../utils";
import { useCarrito } from "../context/CartContext";
import { useSesion } from "../context/SessionContext";
import { useToast } from "../context/ToastContext";

function TarjetaItem({
  item,
  restauranteId,
  destacado = false,
  indice = 0,
}: {
  item: Item;
  restauranteId: number;
  destacado?: boolean;
  indice?: number;
}): JSX.Element {
  const { agregar } = useCarrito();
  const { mostrar } = useToast();
  const [agregando, setAgregando] = useState(false);
  const foto = fotoUrl(restauranteId, item.foto);

  async function handleAgregar(): Promise<void> {
    setAgregando(true);
    try {
      await agregar(item.id);
      mostrar(`${item.nombre} agregado al carrito.`, "exito");
    } catch {
      mostrar("No se pudo agregar el producto.", "error");
    } finally {
      setAgregando(false);
    }
  }

  return (
    <article
      className={`tarjeta${destacado ? " tarjeta--destacada" : ""}`}
      // Entrada escalonada (máx. ~0,4 s para que no se sienta lenta).
      style={{ animationDelay: `${Math.min(indice, 8) * 50}ms` }}
    >
      <div className="tarjeta__foto-wrap">
        {foto ? (
          <img src={foto} alt={item.nombre} className="tarjeta__foto" loading="lazy" />
        ) : (
          <div className="tarjeta__foto tarjeta__foto--vacia">
            <i className="ti-image" />
          </div>
        )}
        {destacado && <span className="badge-pill badge-pill--marca tarjeta__badge-foto">★ Destacado</span>}
        <span className="tarjeta__precio-foto">{formatearCLP(item.precio)}</span>
      </div>
      <div className="tarjeta__cuerpo">
        <div className="tarjeta__titulo-fila">
          <h4>{item.nombre}</h4>
        </div>
        {item.descripcion && <p className="tarjeta__descripcion">{item.descripcion}</p>}
        {item.tiempo && (
          <span className="fila-info">
            <i className="ti-timer" /> {item.tiempo}
          </span>
        )}
        <div className="tarjeta__acciones">
          <button
            className={`boton ${destacado ? "boton--marca" : "boton--primario"} boton--bloque`}
            onClick={handleAgregar}
            disabled={agregando}
          >
            {agregando ? (
              "Agregando..."
            ) : (
              <>
                <i className="ti-plus" /> Agregar al pedido
              </>
            )}
          </button>
        </div>
      </div>
    </article>
  );
}

function TituloCategoria({ texto, conteo, nivel = "h3" }: { texto: string; conteo?: number; nivel?: "h2" | "h3" }): JSX.Element {
  const Etiqueta = nivel;
  return (
    <div className="categoria-titulo">
      <Etiqueta>{texto}</Etiqueta>
      <span className="categoria-titulo__linea" aria-hidden="true" />
      {conteo !== undefined && (
        <span className="categoria-titulo__conteo">
          {conteo} {conteo === 1 ? "producto" : "productos"}
        </span>
      )}
    </div>
  );
}

function SeccionComentarios({ datos, onComentarioNuevo }: { datos: CartaCompleta; onComentarioNuevo: () => void }): JSX.Element {
  const { nombreUsuario } = useSesion();
  const { mostrar } = useToast();
  const [texto, setTexto] = useState("");
  const [enviando, setEnviando] = useState(false);

  async function enviar(ev: FormEvent): Promise<void> {
    ev.preventDefault();
    if (!texto.trim()) return;
    setEnviando(true);
    try {
      await api.comentar(texto.trim());
      setTexto("");
      onComentarioNuevo();
      mostrar("Comentario publicado.", "exito");
    } catch {
      mostrar("No se pudo publicar el comentario.", "error");
    } finally {
      setEnviando(false);
    }
  }

  return (
    <section className="categoria-bloque">
      <TituloCategoria texto="Comentarios" nivel="h2" />
      <div className="caja-comentarios">
        {nombreUsuario ? (
          <form onSubmit={enviar}>
            <textarea
              placeholder="Contanos qué te pareció..."
              value={texto}
              onChange={(e) => setTexto(e.target.value)}
              rows={3}
              maxLength={1000}
            />
            <button type="submit" className="boton boton--primario boton--chico" disabled={enviando}>
              {enviando ? "Publicando..." : "Publicar"}
            </button>
          </form>
        ) : (
          <p className="texto-ayuda">Iniciá sesión para dejar un comentario.</p>
        )}

        {datos.comentarios.length === 0 ? (
          <p className="estado-vacio" style={{ padding: "16px 0" }}>
            Todavía no hay comentarios.
          </p>
        ) : (
          <ul className="lista-comentarios">
            {datos.comentarios.map((c) => (
              <li key={c.id}>
                <span className="avatar" aria-hidden="true">
                  {c.usuario.charAt(0)}
                </span>
                <div>
                  <strong>{c.usuario}</strong>
                  <p style={{ margin: "2px 0 0" }}>{c.comentario}</p>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}

export function Carta(): JSX.Element {
  const { slug } = useParams<{ slug: string }>();
  const [datos, setDatos] = useState<CartaCompleta | null>(null);
  const [noEncontrado, setNoEncontrado] = useState(false);
  const [tabActiva, setTabActiva] = useState<number | null>(null);
  const { esAdmin } = useSesion();

  function cargar(): void {
    if (!slug) return;
    api
      .obtenerCarta(slug)
      .then((d) => {
        setDatos(d);
        setTabActiva(d.secciones[0]?.carta.id ?? null);
      })
      .catch(() => setNoEncontrado(true));
  }

  useEffect(() => {
    setDatos(null);
    setNoEncontrado(false);
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [slug]);

  if (noEncontrado) {
    return (
      <div className="contenedor seccion">
        <p className="estado-vacio">No encontramos ese restaurante.</p>
      </div>
    );
  }

  if (!datos) {
    return (
      <div className="contenedor seccion">
        <div className="skeleton" style={{ height: 120, marginBottom: 28 }} />
        <div className="skeleton" style={{ height: 220 }} />
      </div>
    );
  }

  const { restaurante } = datos;
  const fotoRestaurante = fotoUrl(restaurante.id, restaurante.foto);

  return (
    <div>
      <section
        className="portada-restaurante"
        style={fotoRestaurante ? { backgroundImage: `url(${fotoRestaurante})` } : undefined}
      >
        <div className="contenedor portada-restaurante__fila">
          <img className="portada-restaurante__foto" src={fotoRestaurante ?? "/img/logo_empresa_comodin.png"} alt="" />
          <div className="portada-restaurante__datos">
            <h1>{restaurante.nombre}</h1>
            <div className="portada-restaurante__filas">
              <span className="fila-info">
                <i className="ti-location-pin" /> {restaurante.calle} #{restaurante.numero}, {restaurante.comuna}
                {restaurante.region ? `, ${restaurante.region}` : ""}
              </span>
              {restaurante.fono && (
                <span className="fila-info">
                  <i className="ti-mobile" /> {restaurante.fono}
                </span>
              )}
              {restaurante.email && (
                <span className="fila-info">
                  <i className="ti-email" /> {restaurante.email}
                </span>
              )}
            </div>
          </div>
          <div className="portada-restaurante__acciones">
            {esAdmin && (
              <a className="boton boton--fantasma boton--chico" href="/admin">
                Administrar
              </a>
            )}
          </div>
        </div>
      </section>

      <div className="contenedor seccion">
        {datos.destacados.length > 0 && (
          <section className="categoria-bloque">
            <TituloCategoria texto="Destacados de la casa" conteo={datos.destacados.length} nivel="h2" />
            <div className="grilla-tarjetas">
              {datos.destacados.map((item, i) => (
                <TarjetaItem key={`destacado-${item.id}`} item={item} restauranteId={restaurante.id} destacado indice={i} />
              ))}
            </div>
          </section>
        )}

        {datos.secciones.length > 0 && (
          <>
            <div className="tabs-carta-wrap">
              <div className="tabs-carta" role="tablist">
                {datos.secciones.map((s) => (
                  <button
                    key={s.carta.id}
                    role="tab"
                    aria-selected={tabActiva === s.carta.id}
                    className={`tab-pastilla${tabActiva === s.carta.id ? " activa" : ""}`}
                    onClick={() => setTabActiva(s.carta.id)}
                  >
                    {s.carta.nombre}
                  </button>
                ))}
              </div>
            </div>

            {datos.secciones
              .filter((s) => s.carta.id === tabActiva)
              .map((s) => (
                <div key={s.carta.id}>
                  {s.categoriasConItems.length === 0 && <p className="estado-vacio">No hay información para mostrar.</p>}
                  {s.categoriasConItems.map((ci) => (
                    <div key={ci.categoria.id} className="categoria-bloque">
                      <TituloCategoria texto={ci.categoria.nombre} conteo={ci.items.length} />
                      {ci.items.length === 0 ? (
                        <p className="estado-vacio" style={{ padding: "12px 0" }}>
                          Sin productos por ahora.
                        </p>
                      ) : (
                        <div className="grilla-tarjetas">
                          {ci.items.map((item, i) => (
                            <TarjetaItem key={item.id} item={item} restauranteId={restaurante.id} indice={i} />
                          ))}
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              ))}
          </>
        )}

        <SeccionComentarios datos={datos} onComentarioNuevo={cargar} />
      </div>
    </div>
  );
}
