import Link from "next/link";
import { LoginForm } from "@/components/login";
import { isConfigured } from "@/lib/supabase/server";
export default async function Login({
  searchParams,
}: {
  searchParams: Promise<Record<string, string>>;
}) {
  const p = await searchParams;
  return (
    <main className="auth">
      <p className="eyebrow">ToolTag Workspace</p>
      <h1>Tu espacio de trabajo.</h1>
      <p className="muted">Acceso privado para las cuentas autorizadas.</p>
      {p.notice && (
        <p className="notice">
          Tu cuenta necesita acceso a ToolTag. El administrador debe asignarlo
          antes de entrar.
        </p>
      )}
      {isConfigured() ? (
        <LoginForm />
      ) : (
        <div className="notice">
          Falta configurar la conexión a Supabase.{" "}
          <Link href="/app">Ver estructura de la aplicación →</Link>
        </div>
      )}
      <p style={{ marginTop: 24 }}>
        <Link href="/">← Volver a ToolTag</Link>
      </p>
    </main>
  );
}
