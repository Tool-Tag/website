import { redirect } from "next/navigation";
import { supabase } from "@/lib/supabase/server";
export const TOOLTAG = "10000000-0000-0000-0000-000000000002";
export async function context() {
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
  return { db, user, role: membership.role as string, unit: TOOLTAG };
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
  if (options.id) q = q.eq("id", options.id);
  if (options.field) q = q.eq(options.field, options.value!);
  if (options.order) q = q.order(options.order, { ascending: false });
  const { data, error } = await q.limit(options.limit ?? 200);
  if (error) throw new Error(`Unable to load ${table}: ${error.message}`);
  return data ?? [];
}
