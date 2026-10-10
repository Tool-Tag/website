import Link from "next/link";
import { context } from "@/lib/domain/context";


export default async function PickReturnLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  await context();

  return (
    <div className="workspace driver-workspace">
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
      </header>
      <main className="content">{children}</main>
      <footer className="footer">
        ToolTag Pick &amp; Return · Route operations
      </footer>
    </div>
  );
}
