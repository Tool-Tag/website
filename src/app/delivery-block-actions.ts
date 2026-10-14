"use server";
import { requirePermission } from "@/lib/domain/context";
import { revalidatePath } from "next/cache";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
export type DeliveryDate = { date: string; blocks: { id: string | null; number: number; count: number; capacity: number }[] };
export async function availableDeliveryBlocks(job: string, from: string, leg: "Pickup"|"Return" = "Return") {
  const { db } = await requirePermission("pr.routes.plan");
  const { data, error } = await db.rpc(leg === "Pickup" ? "pickup_block_availability" : "delivery_block_availability", { p_job: job, p_from: from });
  return error ? { error: error.message } : { data: data as DeliveryDate[] };
}
export async function assignDeliveryBlock(job: string, day: string, leg: "Pickup"|"Return" = "Return") {
  const { db } = await requirePermission("pr.routes.plan");
  const { error } = await db.rpc(leg === "Pickup" ? "assign_pickup_block" : "assign_delivery_block", { p_job: job, p_day: day });
  if (error) return { error: error.message };
  await dispatchWorkerMail();
  revalidatePath("/app/pick-return"); revalidatePath("/pick-return", "layout");
  return { ok: true };
}
export async function saveDeliveryBlock(route: string, operator: string, stops: string[], removed: string[], capacity: number, reason: string, leg: "Pickup"|"Return" = "Return") {
  const { db } = await requirePermission("pr.routes.plan");
  const { error } = await db.rpc(leg === "Pickup" ? "save_pickup_block" : "save_delivery_block", { p_route: route, p_operator: operator || null, p_stops: stops, p_removed: removed, p_capacity: capacity, p_reason: reason || null });
  if (error) return { error: error.message };
  revalidatePath("/app/pick-return"); revalidatePath("/pick-return", "layout");
  return { ok: true };
}
