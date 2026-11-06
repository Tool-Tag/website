import {WorkspaceBrand} from "@/components/hex-icon";
import { StaffLoginAttention } from "@/components/staff-login-attention";
import { SessionTimeout } from "@/components/session-timeout";
import Link from "next/link";
import { PermissionProvider } from "@/components/permission-provider";
import { driverOnly } from "@/lib/auth/permissions";
import { logout } from "@/app/actions";
import { requirePermission } from "@/lib/domain/context";


export default async function PickReturnLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const ctx = await requirePermission("driver.routes","pr.routes.live","pr.routes.plan","pr.receiving","pr.returns","pr.reschedule");

  return (
    <PermissionProvider access={ctx.access}><SessionTimeout expiresAt={ctx.session.expires_at} serverNow={ctx.session.server_now}/><StaffLoginAttention db={ctx.db} sessionId={ctx.session.session_id}/><div className="workspace driver-workspace">
      <header className="topbar driver-road-header">
        <Link className="brand" href="/pick-return">
          <WorkspaceBrand subtitle="On the road"/>
        </Link>
        {!driverOnly(ctx.access) && <Link className="button secondary" href="/app">
          Back to Workspace
        </Link>}
        <Link className="button secondary" href="/pick-return/policies-and-conditions">Policies and conditions</Link>
        <form action={logout}><button className="secondary">Sign Out</button></form>
      </header>
      <main className="content">{children}</main>
      <footer className="footer">
        ToolTag Pick up &amp; Delivery · Route operations
      </footer>
    </div></PermissionProvider>
  );
}
