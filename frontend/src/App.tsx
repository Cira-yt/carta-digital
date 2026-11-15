import { Routes, Route } from "react-router-dom";
import { Layout } from "./components/Layout";
import { Bienvenida } from "./pages/Bienvenida";
import { Carrito } from "./pages/Carrito";
import { Carta } from "./pages/Carta";
import { NoEncontrado } from "./pages/NoEncontrado";

export function App(): JSX.Element {
  return (
    <Routes>
      <Route element={<Layout />}>
        {/* "/" muestra el selector público de restaurantes (ver Bienvenida.tsx);
            cada uno también se puede abrir directo por su slug en /<slug>. */}
        <Route path="/" element={<Bienvenida />} />
        {/* Rutas estáticas ANTES del slug dinámico, para que no choquen. */}
        <Route path="/carrito" element={<Carrito />} />
        <Route path="/:slug" element={<Carta />} />
        <Route path="*" element={<NoEncontrado />} />
      </Route>
    </Routes>
  );
}
