import type { SupabaseClient } from "@supabase/supabase-js";

export type WorkspaceAttention = {
  getTagged: number;
  quotes: number;
  jobs: number;
  refunds: number;
};

type GetTaggedAttentionRow = {
  quote_id?: string | null;
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
    const [requests, quotes, jobs, refunds, routeRefunds] = await Promise.all([
      db.rpc("get_tagged_attention"),
      db
        .from("quotes")
        .select("id,status,source,intake_reviewed_at")
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
      db.from("route_compensations").select("id,status,amount,paid_amount").eq("unit_id",unit).neq("status","Completed"),
    ]);

    const requestRows: GetTaggedAttentionRow[] = Array.isArray(requests.data)
      ? requests.data
      : [];
    const requestReviewQuoteIds = new Set(
      requestRows
        .map((request) => request.quote_id)
        .filter((quoteId): quoteId is string => Boolean(quoteId)),
    );

    const jobRows = jobs.data ?? [];
    const jobQuoteIds = new Set(
      jobRows
        .map((job) => job.quote_id)
        .filter((quoteId): quoteId is string => Boolean(quoteId)),
    );

    const openQuotes = (quotes.data ?? []).filter((quote) => {
      if (jobQuoteIds.has(quote.id)) return false;

      const stillInRequestReview =
        quote.source === "public_get_tagged" &&
        quote.status === "Draft" &&
        !quote.intake_reviewed_at &&
        requestReviewQuoteIds.has(quote.id);

      return !stillInRequestReview;
    });

    const openJobs = jobRows.filter(
      (job) => job.status !== "Cancelled" && job.work_stage !== "Closed",
    );

    const pendingRefunds = (refunds.data ?? []).filter(
      (request) => Number(request.refund_eligible_amount ?? 0) > 0,
    );

    return {
      getTagged: requestRows.length,
      quotes: openQuotes.length,
      jobs: openJobs.length,
      refunds: pendingRefunds.length+(routeRefunds.data??[]).filter(r=>Number(r.amount)>Number(r.paid_amount)).length,
    };
  } catch {
    return ZERO;
  }
}
