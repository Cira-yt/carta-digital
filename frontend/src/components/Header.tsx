import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useSesion } from "../context/SessionContext";
import { useCarrito } from "../context/CartContext";
import { useToast } from "../context/ToastContext";
import { LoginModal } from "./LoginModal";

export function Header(): JSX.Element {
  const { nombreUsuario, esAdmin, logout } = useSesion();
  const { cantidad } = useCarrito();
  const { mostrar } = useToast();
  const [mostrarLogin, setMostrarLogin] = useState(false);
  // Pequeño "pulso" en el contador cada vez que cambia la cantidad.
  const [pulso, setPulso] = useState(false);
  const cantidadAnterior = useRef(cantidad);
  useEffect(() => {
    if (cantidad > cantidadAnterior.current) {
      setPulso(true);
      const t = setTimeout(() => setPulso(false), 450);
      cantidadAnterior.current = cantidad;
      return () => clearTimeout(t);
    }
    cantidadAnterior.current = cantidad;
  }, [cantidad]);

  async function cerrarSesion(): Promise<void> {
    await logout();
    mostrar("Sesión cerrada.", "info");
  }

  return (
    <header className="barra-publica">
      <div className="contenedor barra-publica__fila">
        <Link to="/" className="barra-publica__marca">
          <span className="barra-publica__marca-icono">
            <i className="ti-receipt" />
          </span>
          <span className="barra-publica__marca-texto">Carta Digital</span>
        </Link>

        <div className="barra-publica__acciones">
          {nombreUsuario ? (
            <>
              <span className="barra-publica__saludo">
                <span className="avatar" aria-hidden="true">
                  {nombreUsuario.charAt(0)}
                </span>
                <span className="nombre">{nombreUsuario}</span>
              </span>
              {esAdmin && (
                <a className="boton boton--fantasma boton--chico" href="/admin">
                  Panel admin
                </a>
              )}
              <button className="boton boton--fantasma boton--chico" onClick={cerrarSesion}>
                Cerrar sesión
              </button>
            </>
          ) : (
            <button className="boton boton--fantasma boton--chico" onClick={() => setMostrarLogin(true)}>
              Ingresar
            </button>
          )}

          <Link to="/carrito" className="carrito-link" aria-label={`Ver carrito (${cantidad} productos)`}>
            <i className="ti-shopping-cart" />
            <span className="carrito-link__texto">Mi pedido</span>
            {cantidad > 0 && (
              <span className={`carrito-badge${pulso ? " carrito-badge--pulso" : ""}`}>{cantidad}</span>
            )}
          </Link>
        </div>
      </div>

      {mostrarLogin && <LoginModal onCerrar={() => setMostrarLogin(false)} />}
    </header>
  );
}
