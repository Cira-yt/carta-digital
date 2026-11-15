import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { api, RestauranteResumen } from "../api";
import { fotoUrl } from "../utils";

function TarjetaRestaurante({ restaurante }: { restaurante: RestauranteResumen }): JSX.Element {
  const foto = fotoUrl(restaurante.id, restaurante.foto);
  return (
    <Link to={`/${restaurante.slug}`} className="tarjeta tarjeta--restaurante">
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
        <span className="fila-info">
          <i className="ti-arrow-right" /> Ver carta
        </span>
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
        <div className="contenedor" style={{ textAlign: "center" }}>
          <div className="hero-publico__icono" aria-hidden="true">
            <i className="ti-location-pin" />
          </div>
          <span className="hero-publico__etiqueta">Carta Digital</span>
          <h1>
            Elige tu restaurante
            <br />
            <em>y revisa la carta</em>
          </h1>
          <p style={{ margin: "0 auto" }}>
            Busca el local que quieres ver y entra directo a su carta digital, con fotos y precios.
          </p>
        </div>
      </section>

      <div className="contenedor seccion">
        {restaurantes && restaurantes.length > 0 && (
          <div className="buscador-inicio">
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
            {filtrados.map((r) => (
              <TarjetaRestaurante key={r.id} restaurante={r} />
            ))}
          </div>
        )}
      </div>
    </>
  );
}
