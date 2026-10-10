import Link from "next/link";
import { context } from "@/lib/domain/context";
import { logout } from "@/app/actions";

export default async function PickReturnLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const { user } = await context();

  return (
    <div className="workspace">
      <header className="topbar">
        <Link className="brand" href="/pick-return">
          Tool<span>Tag</span>
          <small style={{ fontSize: 10, display: "block", letterSpacing: 3 }}>
            PICK &amp; RETURN
          </small>
        </Link>
        <Link className="button secondary" href="/app">
          Back to Workspace
        </Link>
        <span className="muted user">{user.email}</span>
        <form action={logout}>
          <button className="secondary">Sign out</button>
        </form>
      </header>
      <main className="content">{children}</main>
      <footer className="footer">
        ToolTag Pick &amp; Return · Route operations
      </footer>
    </div>
  );
}
