import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { App } from "./App";
import { SessionProvider } from "./context/SessionContext";
import { CartProvider } from "./context/CartContext";
import { ToastProvider } from "./context/ToastContext";
// Tipografías autoalojadas (Vite las empaqueta en /assets: sin Google Fonts).
import "@fontsource-variable/fraunces/opsz.css";
import "@fontsource-variable/fraunces/opsz-italic.css";
import "@fontsource-variable/plus-jakarta-sans";
import "./styles/global.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <BrowserRouter>
      <ToastProvider>
        <SessionProvider>
          <CartProvider>
            <App />
          </CartProvider>
        </SessionProvider>
      </ToastProvider>
    </BrowserRouter>
  </React.StrictMode>
);
