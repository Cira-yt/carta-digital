import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { api, RestauranteResumen } from "../api";
import { fotoUrl } from "../utils";

function TarjetaRestaurante({
  restaurante,
  destacada,
}: {
  restaurante: RestauranteResumen;
  destacada?: boolean;
}): JSX.Element {
  const foto = fotoUrl(restaurante.id, restaurante.foto);
  return (
    <Link
      to={`/${restaurante.slug}`}
      className={`tarjeta tarjeta--restaurante${destacada ? " tarjeta--restaurante-destacada" : ""}`}
    >
      <div className="tarjeta__foto-wrap">
        {foto ? (
          <img src={foto} alt={restaurante.nombre} className="tarjeta__foto" loading="lazy" />
        ) : (
          <div className="tarjeta__foto tarjeta__foto--vacia">
            <i className="ti-location-pin" aria-hidden="true" />
          </div>
        )}
      </div>
      <div className="tarjeta__cuerpo">
        <div className="tarjeta__titulo-fila">
          <h3>{restaurante.nombre}</h3>
        </div>
        <span className="fila-info fila-info--sutil">Carta digital disponible</span>
      </div>
    </Link>
  );
}

export function Bienvenida(): JSX.Element {
  const [restaurantes, setRestaurantes] = useState<RestauranteResumen[] | null>(null);
  const [error, setError] = useState(false);
  const [busqueda, setBusqueda] = useState("");

  useEffect(() => {
    api
      .listarRestaurantes()
      .then((d) => setRestaurantes(d.restaurantes))
      .catch(() => setError(true));
  }, []);

  const filtrados = useMemo(() => {
    if (!restaurantes) return [];
    const texto = busqueda.trim().toLowerCase();
    if (!texto) return restaurantes;
    return restaurantes.filter((r) => r.nombre.toLowerCase().includes(texto));
  }, [restaurantes, busqueda]);

  return (
    <>
      <section className="hero-publico">
        <div className="contenedor">
          <div>
            <h1>Elige dónde comer hoy</h1>
            <p>Entra directo a la carta del local que buscas: fotos, precios y pedidos en un mismo lugar.</p>
            {restaurantes && restaurantes.length > 0 && (
              <div className="buscador-inicio buscador-inicio--clara">
                <i className="ti-search" aria-hidden="true" />
                <input
                  type="search"
                  placeholder="Busca un restaurante por nombre..."
                  value={busqueda}
                  onChange={(e) => setBusqueda(e.target.value)}
                  aria-label="Buscar restaurante"
                />
              </div>
            )}
          </div>
          {restaurantes && restaurantes.length > 0 && (
            <div className="hero-publico__cifras">
              <div className="hero-publico__cifra">
                <strong>{restaurantes.length}</strong>
                <span>
                  {restaurantes.length === 1 ? "restaurante" : "restaurantes"}
                  <br />
                  publicados
                </span>
              </div>
            </div>
          )}
        </div>
      </section>

      <div className="contenedor seccion">
        {error && (
          <div className="estado-vacio-tarjeta">
            <i className="ti-alert estado-vacio-tarjeta__icono" aria-hidden="true" />
            <p className="estado-vacio" style={{ padding: 0 }}>
              No pudimos cargar los restaurantes. Intenta de nuevo en un momento.
            </p>
          </div>
        )}

        {!error && !restaurantes && (
          <div className="grilla-tarjetas">
            {[0, 1, 2].map((i) => (
              <div key={i} className="skeleton" style={{ height: 230 }} />
            ))}
          </div>
        )}

        {!error && restaurantes && restaurantes.length === 0 && (
          <div className="estado-vacio-tarjeta">
            <i className="ti-location-pin estado-vacio-tarjeta__icono" aria-hidden="true" />
            <p className="estado-vacio" style={{ padding: 0 }}>
              Todavía no hay restaurantes publicados.
            </p>
          </div>
        )}

        {!error && restaurantes && restaurantes.length > 0 && filtrados.length === 0 && (
          <p className="estado-vacio">No encontramos restaurantes con ese nombre.</p>
        )}

        {filtrados.length > 0 && (
          <div className="grilla-tarjetas">
            {filtrados.map((r, i) => (
              <TarjetaRestaurante key={r.id} restaurante={r} destacada={i === 0 && !busqueda} />
            ))}
          </div>
        )}
      </div>
    </>
  );
}
