import { cache } from "react";
import { canAny, driverOnly, type Access } from "@/lib/auth/permissions";
import { redirect } from "next/navigation";
import { supabase } from "@/lib/supabase/server";
export const TOOLTAG = "10000000-0000-0000-0000-000000000002";
export const context = cache(async () => {
  const db = await supabase();
  const {
    data: { user },
    error,
  } = await db.auth.getUser();
  if (error || !user) redirect("/login");
  const { data: membership } = await db
    .from("memberships")
    .select("role")
    .eq("unit_id", TOOLTAG)
    .eq("user_id", user.id)
    .maybeSingle();
  if (!membership) redirect("/login?notice=membership");
  const { data: permissions, error: accessError } = await db.rpc("staff_permissions");
  if (accessError || !permissions?.active) redirect("/login?notice=access");
  const access: Access = { owner: permissions.owner === true, blocks: Array.isArray(permissions.blocks) ? permissions.blocks : [] };
  if (!access.owner && access.blocks.length === 0) redirect("/login?notice=access");
  return { db, user, access, role: access.owner ? "admin" : driverOnly(access) ? "driver" : "employee", unit: TOOLTAG };
});
export async function requirePermission(...blocks: string[]) {
  const ctx = await context();
  if (!canAny(ctx.access, blocks)) throw new Error("Permission denied.");
  return ctx;
}
export async function requireOwner() {
  const ctx = await context();
  if (!ctx.access.owner) throw new Error("Owner access required.");
  return ctx;
}
export async function rows(
  table: string,
  options: {
    unit?: boolean;
    order?: string;
    id?: string;
    field?: string;
    value?: string;
    limit?: number;
  } = {},
) {
  const { db, unit } = await context();
  let q = db.from(table).select("*");
  if (options.unit !== false)
    q =
      table === "categories"
        ? q.or(`unit_id.eq.${unit},unit_id.is.null`)
        : q.eq("unit_id", unit);
  if (table === "jobs" && !options.id) q = q.eq("is_lost", false);
  if (options.id) q = q.eq("id", options.id);
  if (options.field) q = q.eq(options.field, options.value!);
  if (options.order) q = q.order(options.order, { ascending: false });
  const { data, error } = await q.limit(options.limit ?? 200);
  if (error) throw new Error(`Unable to load ${table}: ${error.message}`);
  return data ?? [];
}
