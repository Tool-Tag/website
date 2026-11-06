import {WorkspaceHeader} from "@/components/workspace-header";
import { StaffLoginAttention } from "@/components/staff-login-attention";
import { SessionTimeout } from "@/components/session-timeout";
import { PermissionProvider } from "@/components/permission-provider";
import {type UserMenuLink} from "@/components/workspace-user-menu";
import { canAny, driverOnly, sectionPermissions } from "@/lib/auth/permissions";
import { redirect } from "next/navigation";
import { BackNavigation } from "@/components/back-navigation";
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
  const {data: staffProfile} = ctx ? await ctx.db.from("staff_access").select("display_name").eq("unit_id",ctx.unit).eq("user_id",ctx.user.id).maybeSingle() : {data:null};
  const metadata=ctx?.user.user_metadata;
  const userName=[staffProfile?.display_name,metadata?.full_name,metadata?.name].find((name):name is string=>typeof name==="string"&&name.trim().length>0)?.trim() || "Team member";
  const userLinks:UserMenuLink[]=[
    ...(ctx&&canAny(ctx.access,sectionPermissions("finance-hub"))?[{label:"Finance Hub",href:"/app/finance-hub"}]:[]),
    ...(ctx?.access.owner?[{label:"Settings",href:"/app/settings"}]:[]),
    ...(ctx&&canAny(ctx.access,["driver.routes","pr.routes.live","pr.routes.plan","pr.receiving","pr.returns","pr.reschedule"])?[{label:"Pick up & Delivery Mode",href:"/pick-return"}]:[]),
    {label:"Public Site",href:"/"},
    {label:"Falcon & Times",href:"/hub"},
  ];
  const attention = ctx ? await workspaceAttention(ctx.db, ctx.unit) : undefined;
  return (
    <PermissionProvider access={ctx?.access ?? {owner:false,blocks:[]}}>{ctx && <><SessionTimeout expiresAt={ctx.session.expires_at} serverNow={ctx.session.server_now}/><StaffLoginAttention db={ctx.db} sessionId={ctx.session.session_id}/></>}<div className="shell">
      <aside className="sidebar">
        <Nav attention={attention} access={ctx?.access} grouped utilities={userLinks}/><p className="hex-sidebar-note">ToolTag operations<br/>Bandits of the Framing LLC</p>
      </aside>
      <div className="workspace">
        <WorkspaceHeader name={ctx?userName:"Initial setup"} role={ctx?.access.owner?"Owner":ctx?"Team member":"Initial setup"} canSearch={!!ctx&&canAny(ctx.access,["customers.view"])} navigation={<Nav attention={attention} access={ctx?.access} grouped utilities={userLinks}/>} accountLinks={userLinks.filter(link=>["/app/settings","/"].includes(link.href))} attention={attention} allowedQueues={["get-tagged","quotes","jobs","support","refunds","lost"].filter(section=>ctx&&canAny(ctx.access,sectionPermissions(section))).map(section=>`/app/${section}`)} signOut={ctx?<form action={logout}><button>Sign Out</button></form>:null}/>
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
