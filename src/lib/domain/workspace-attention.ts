import type { SupabaseClient } from "@supabase/supabase-js";

export type WorkspaceAttention = {
  getTagged: number;
  quotes: number;
  jobs: number;
  refunds: number;
};

const ZERO: WorkspaceAttention = {
  getTagged: 0,
  quotes: 0,
  jobs: 0,
  refunds: 0,
};

export async function workspaceAttention(
  db: SupabaseClient,
  unit: string,
): Promise<WorkspaceAttention> {
  try {
    const [requests, quotes, jobs, refunds] = await Promise.all([
      db.rpc("get_tagged_attention"),
      db
        .from("quotes")
        .select("id,status")
        .eq("unit_id", unit)
        .in("status", ["Draft", "Sent", "Viewed", "Agreement Pending", "Accepted"]),
      db
        .from("jobs")
        .select("id,quote_id,status,work_stage")
        .eq("unit_id", unit),
      db
        .from("cancellation_requests")
        .select("id,refund_status,refund_eligible_amount")
        .eq("unit_id", unit)
        .eq("refund_status", "Pending"),
    ]);

    const jobRows = jobs.data ?? [];
    const jobQuoteIds = new Set(
      jobRows
        .map((job) => job.quote_id)
        .filter((quoteId): quoteId is string => Boolean(quoteId)),
    );

    const openQuotes = (quotes.data ?? []).filter((quote) => {
      if (quote.status === "Accepted") {
        return !jobQuoteIds.has(quote.id);
      }
      return !jobQuoteIds.has(quote.id);
    });

    const openJobs = jobRows.filter(
      (job) =>
        job.status !== "Cancelled" &&
        job.work_stage !== "Closed",
    );

    const pendingRefunds = (refunds.data ?? []).filter(
      (request) => Number(request.refund_eligible_amount ?? 0) > 0,
    );

    return {
      getTagged: Array.isArray(requests.data) ? requests.data.length : 0,
      quotes: openQuotes.length,
      jobs: openJobs.length,
      refunds: pendingRefunds.length,
    };
  } catch {
    return ZERO;
  }
}
