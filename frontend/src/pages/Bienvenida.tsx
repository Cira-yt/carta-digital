// No hay selector público de restaurantes: cada restaurante se accede
// escaneando el código QR de su mesa, que apunta directo a /<slug>
// (ver App.tsx). Esta es solo la pantalla que se ve si alguien entra a "/"
// sin un slug (por error, o probando el sitio).
export function Bienvenida(): JSX.Element {
  return (
    <>
      <section className="hero-publico">
        <div className="contenedor" style={{ textAlign: "center" }}>
          <div className="hero-publico__icono" aria-hidden="true">
            <i className="ti-mobile" />
          </div>
          <span className="hero-publico__etiqueta">Carta Digital</span>
          <h1>
            Escaneá el código QR
            <br />
            <em>de tu mesa</em>
          </h1>
          <p style={{ margin: "0 auto" }}>
            Cada mesa tiene su propio código QR que te lleva directo a la carta del restaurante.
          </p>
        </div>
      </section>

      <div className="contenedor">
        <div className="pasos">
          <div className="paso">
            <span className="paso__numero">01</span>
            <h3>Escaneá</h3>
            <p>Apuntá la cámara de tu celular al QR que está en la mesa.</p>
          </div>
          <div className="paso">
            <span className="paso__numero">02</span>
            <h3>Elegí</h3>
            <p>Mirá la carta con fotos y precios, y armá tu pedido.</p>
          </div>
          <div className="paso">
            <span className="paso__numero">03</span>
            <h3>Confirmá</h3>
            <p>Confirmá desde el celular o avisale al garzón tu número de pedido.</p>
          </div>
        </div>
      </div>
    </>
  );
}
