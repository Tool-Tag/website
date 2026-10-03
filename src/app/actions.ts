"use server";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { context } from "@/lib/domain/context";
import { supabase } from "@/lib/supabase/server";
import { cents } from "@/lib/domain/money";
import { z } from "zod";
export type ActionState = { error?: string; ok?: boolean; link?: string };
export async function login(
  _: ActionState,
  form: FormData,
): Promise<ActionState> {
  const db = await supabase();
  const { error } = await db.auth.signInWithPassword({
    email: String(form.get("email")),
    password: String(form.get("password")),
  });
  if (error)
    return {
      error:
        "No se pudo iniciar sesión. Revisa tus datos y que la cuenta esté habilitada.",
    };
  redirect("/app");
}
export async function logout() {
  const db = await supabase();
  await db.auth.signOut();
  redirect("/login");
}
export async function mutate(
  operation: string,
  back: string,
  _: ActionState,
  form: FormData,
): Promise<ActionState> {
  let destination: string | undefined;
  try {
    const { db, unit, role } = await context();
    if (role !== "admin") return { error: "Esta cuenta es de consulta." };
    const p: Record<string, unknown> = {
      ...Object.fromEntries(form.entries()),
      unit_id: unit,
    };
    for (const [k, v] of Object.entries(p)) {
      if (v === "") delete p[k];
    }
    let name = "",
      args: Record<string, unknown> = { p };
    switch (operation) {
      case "customer":
        z.object({
          name: z.string().min(1),
          email: z.email(),
          phone: z.string().min(3),
          address: z.string().min(1),
        }).parse(p);
        name = "save_customer";
        break;
      case "quote":
        p.items = JSON.parse(String(p.items));
        name = "create_quote";
        break;
      case "movement":
        cents(String(p.amount));
        name = "record_movement";
        break;
      case "asset":
        name = "create_asset";
        break;
      case "document":
        name = "add_document";
        break;
      case "update-transaction":
        name = "update_transaction";
        break;
      case "publish-policy":
        name = "publish_policy";
        args = { p_unit: unit, p_title: p.title, p_content: p.content };
        break;
      case "send-quote":
        name = "send_quote";
        args = { p_id: p.id };
        break;
      case "job":
        name = "advance_job";
        args = { p_id: p.id, p_action: p.action };
        break;
      case "notified":
        name = "confirm_completion_notified";
        args = { p_id: p.id };
        break;
      case "close":
        name = "close_month";
        args = { p_unit: unit, p_month: p.month };
        break;
      case "settings":
        name = "save_settings";
        break;
      case "mileage":
        name = "record_mileage";
        break;
      case "category":
        name = "save_category";
        break;
      default:
        return { error: "Acción desconocida" };
    }
    const { data, error } = await db.rpc(name, args);
    if (error) return { error: error.message };
    revalidatePath("/app", "layout");
    if (operation === "send-quote") return { link: `/accept/${data}` };
    if (operation === "job" && data) return { link: `/completion/${data}` };
    if (operation === "customer") destination = `/app/customers/${data}`;
    else if (operation === "quote") destination = `/app/quotes/${data}`;
    else if (operation === "movement" && p.type === "EXPENSE")
      destination = `/app/finance/expenses?created=${data}`;
    else if (back.startsWith("/app")) destination = back;
  } catch (e) {
    return { error: e instanceof Error ? e.message : "No se pudo guardar" };
  }
  if (destination) redirect(destination);
  return { ok: true };
}
export async function customerAction(
  kind: string,
  token: string,
  _: ActionState,
  form: FormData,
): Promise<ActionState> {
  const db = await supabase();
  const args =
    kind === "quote"
      ? { p_token: token }
      : kind === "agreement"
        ? {
            p_token: token,
            p_name: String(form.get("name")),
            p_email: String(form.get("email")),
            p_phone: String(form.get("phone")),
          }
        : { p_token: token, p_decision: kind };
  if (
    (kind === "quote" || kind === "agreement") &&
    form.get("confirmed") !== "on"
  )
    return { error: "Confirma que revisaste y aceptas el contenido." };
  const { error } = await db.rpc(
    kind === "quote"
      ? "accept_quote"
      : kind === "agreement"
        ? "accept_agreement"
        : "public_completion",
    args,
  );
  if (error) return { error: error.message };
  revalidatePath(`/accept/${token}`);
  revalidatePath(`/completion/${token}`);
  return { ok: true };
}
