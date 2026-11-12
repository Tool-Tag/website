import { cache } from "react";
import { SHOP_BOARD_ORDER_KEYS } from "./shop-board-data";
import type { SupabaseClient } from "@supabase/supabase-js";

const PAGE_SIZE = 500;
type QueueJob = { id: string; quote_id: string; code: string; status: string; work_stage: string; created_at: string };
type PendingLogistics = { job_id: string };

export const workspaceJobQueues = cache(async (db: SupabaseClient, unit: string) => {
  async function read<T>(table: "jobs" | "quote_logistics") {
    const rows: T[] = [];
    for (let offset = 0; ; offset += PAGE_SIZE) {
      const columns = table === "jobs" ? "id,quote_id,code,status,work_stage,created_at" : "job_id";
      const base = db.from(table).select(columns).eq("unit_id", unit);
      const query = table === "jobs" ? base.eq("is_lost", false)
        : base.in("payment_status", ["pending", "pending_verification"]).not("job_id", "is", null);
      const { data, error } = await query.order(SHOP_BOARD_ORDER_KEYS[table]).range(offset, offset + PAGE_SIZE - 1).returns<T[]>();
      if (error) throw new Error(`Could not load ${table}.`);
      rows.push(...data);
      if (data.length < PAGE_SIZE) return rows;
    }
  }

  const [jobs, pendingLogistics] = await Promise.all([read<QueueJob>("jobs"), read<PendingLogistics>("quote_logistics")]);
  const pendingLogisticsJobs = new Set(pendingLogistics.map(entry => entry.job_id));
  const queues: Record<"active" | "review" | "payments" | "completed" | "cancelled", QueueJob[]> = {
    active: [], review: [], payments: [], completed: [], cancelled: [],
  };
  for (const job of jobs) {
    if (job.status === "Cancelled") queues.cancelled.push(job);
    else if (job.status === "Completed" || job.work_stage === "Closed") queues.completed.push(job);
    else if (job.status === "Issue / Review" || job.work_stage === "Issue Review") queues.review.push(job);
    else if (["Payment", "Payment Verification"].includes(job.work_stage) || pendingLogisticsJobs.has(job.id)) queues.payments.push(job);
    else queues.active.push(job);
  }
  return { jobs, ...queues };
});
