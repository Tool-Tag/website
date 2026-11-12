import { cache } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";

const PAGE_SIZE = 500;

export const workspaceJobQueues = cache(async (db: SupabaseClient, unit: string) => {
  async function read(table: "jobs" | "quote_logistics") {
    const rows = [];
    for (let offset = 0; ; offset += PAGE_SIZE) {
      const base = db.from(table).select("*").eq("unit_id", unit);
      const query = table === "jobs" ? base.eq("is_lost", false)
        : base.in("payment_status", ["pending", "pending_verification"]).not("job_id", "is", null);
      const { data, error } = await query.order("id").range(offset, offset + PAGE_SIZE - 1);
      if (error) throw new Error(`Could not load ${table}.`);
      rows.push(...data);
      if (data.length < PAGE_SIZE) return rows;
    }
  }

  const [jobs, pendingLogistics] = await Promise.all([read("jobs"), read("quote_logistics")]);
  const pendingLogisticsJobs = new Set(pendingLogistics.map(entry => entry.job_id));
  const active = jobs.filter(job =>
    !["Cancelled", "Completed", "Issue / Review"].includes(job.status) &&
    !["Payment", "Payment Verification", "Closed", "Issue Review"].includes(job.work_stage) &&
    !pendingLogisticsJobs.has(job.id),
  );
  return { jobs, active, pendingLogisticsJobs };
});
