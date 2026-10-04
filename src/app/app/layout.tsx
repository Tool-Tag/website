import { BackNavigation } from "@/components/back-navigation";
import Link from "next/link";
import { context } from "@/lib/domain/context";
import { isConfigured } from "@/lib/supabase/server";
import { Nav } from "@/components/nav";
import { logout } from "@/app/actions";
export default async function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const ctx = isConfigured() ? await context() : null;
  return (
    <div className="shell">
      <aside className="sidebar">
        <Link className="brand" href="/app">
          Tool<span>Tag</span>
          <small style={{ fontSize: 10, display: "block", letterSpacing: 3 }}>
            WORKSPACE
          </small>
        </Link>
        <Nav />
        <div className="sidebar-bottom">
          <Nav bottom />
          <p>
            <Link className="muted" href="/">
              ↗ Sitio público
            </Link>
          </p>
          <Link className="muted" href="/hub">
            Falcon y Tiempos ↗
          </Link>
        </div>
      </aside>
      <div className="workspace">
        <header className="topbar">
          <form action="/app/customers">
            <input
              name="q"
              placeholder="Buscar cliente, trabajo o cotización…"
              aria-label="Buscar cliente o registro"
            />
          </form>
          <span className="muted user">
            {ctx?.user.email ?? "Configuración inicial"}
          </span>
          {ctx && (
            <form action={logout}>
              <button className="secondary">Salir</button>
            </form>
          )}
        </header>
        <main className="content">
          {!ctx && (
            <div className="notice">
              Falta conectar Supabase. Esta vista muestra la estructura; no
              contiene datos de prueba ni permite guardar.
            </div>
          )}
          <BackNavigation />
          {children}
        </main>
        <footer className="footer">
          ToolTag is a registered DBA of Bandits of the Framing LLC.
        </footer>
      </div>
    </div>
  );
}
