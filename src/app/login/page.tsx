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
      <h1>Your Workspace.</h1>
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
          The Supabase connection is not configured.{" "}
          <Link href="/app">View Application Structure →</Link>
        </div>
      )}
      <p style={{ marginTop: 24 }}>
        <Link href="/">← Back to ToolTag</Link>
      </p>
    </main>
  );
}
