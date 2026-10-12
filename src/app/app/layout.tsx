import { PermissionProvider } from "@/components/permission-provider";
import { canAny, driverOnly } from "@/lib/auth/permissions";
import { redirect } from "next/navigation";
import { BackNavigation } from "@/components/back-navigation";
import Link from "next/link";
import { context } from "@/lib/domain/context";
import { isConfigured } from "@/lib/supabase/server";
import { Nav } from "@/components/nav";
import { logout } from "@/app/actions";
import { workspaceAttention } from "@/lib/domain/workspace-attention";
export default async function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const ctx = isConfigured() ? await context() : null;
  if (ctx && driverOnly(ctx.access)) redirect("/pick-return");
  const attention = ctx ? await workspaceAttention(ctx.db, ctx.unit) : undefined;
  return (
    <PermissionProvider access={ctx?.access ?? {owner:false,blocks:[]}}><div className="shell">
      <aside className="sidebar">
        <Link className="brand" href="/app">
          Tool<span>Tag</span>
          <small style={{ fontSize: 10, display: "block", letterSpacing: 3 }}>
            WORKSPACE
          </small>
        </Link>
        <Nav attention={attention} access={ctx?.access} />
        <div className="sidebar-bottom">
          <Nav bottom access={ctx?.access} />
          {ctx && canAny(ctx.access,["driver.routes","pr.routes.live","pr.routes.plan","pr.receiving","pr.returns","pr.reschedule"]) && <p>
            <Link className="muted" href="/pick-return">
              Pick & Return Mode ↗
            </Link>
          </p>}
          <p>
            <Link className="muted" href="/">
              ↗ Public Site
            </Link>
          </p>
          <Link className="muted" href="/hub">
            Falcon & Times ↗
          </Link>
        </div>
      </aside>
      <div className="workspace">
        <header className="topbar">
          {ctx && canAny(ctx.access,["pr.routes.plan","pr.routes.live","pr.receiving","pr.returns","pr.reschedule"]) && <Link className="button secondary" href="/app/pick-return">Pick up &amp; Return</Link>}
          {ctx && canAny(ctx.access,["customers.view"]) && <form action="/app/customers">
            <input
              name="q"
              placeholder="Search customer, Job, or Quote…"
              aria-label="Search customer or record"
            />
          </form>}
          <span className="muted user">
            {ctx?.user.email ?? "Initial setup"}
          </span>
          {ctx && (
            <form action={logout}>
              <button className="secondary">Sign Out</button>
            </form>
          )}
        </header>
        <main className="content">
          {!ctx && (
            <div className="notice">
              Supabase is not connected. This view shows the structure only and
              cannot save data.
            </div>
          )}
          <BackNavigation />
          {children}
        </main>
        <footer className="footer">
          ToolTag is a registered DBA of Bandits of the Framing LLC.
        </footer>
      </div>
    </div></PermissionProvider>
  );
}
