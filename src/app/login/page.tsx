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
      <h1>Your workspace.</h1>
      <p className="muted">Private access for authorized accounts.</p>
      {p.notice && (
        <p className="notice">
          Your account needs ToolTag access. An administrator must assign it
          antes de entrar.
        </p>
      )}
      {isConfigured() ? (
        <LoginForm />
      ) : (
        <div className="notice">
          The Supabase connection is not configured yet.{" "}
          <Link href="/app">View application structure →</Link>
        </div>
      )}
      <p style={{ marginTop: 24 }}>
        <Link href="/">← Volver a ToolTag</Link>
      </p>
    </main>
  );
}
