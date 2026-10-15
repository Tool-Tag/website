import {classifyAttention,categoryBadge,type AttentionRecord,type Urgency} from "./urgent-attention";
import type { SupabaseClient } from "@supabase/supabase-js";

export type WorkspaceAttention = {
  getTagged: number;
  quotes: number;
  jobs: number;
  refunds: number;
  notifications: number;
  lost: number;
  urgency?: {notifications:Urgency;refunds:Urgency;lost:Urgency};
};

type GetTaggedAttentionRow = {
  quote_id?: string | null;
};

const ZERO: WorkspaceAttention = {
  getTagged: 0,
  quotes: 0,
  jobs: 0,
  refunds: 0,
  notifications: 0,
  lost: 0,
};

export async function workspaceAttention(
  db: SupabaseClient,
  unit: string,
): Promise<WorkspaceAttention> {
  try {
    const [requests, quotes, jobs, refunds, support, urgent] = await Promise.all([
      db.rpc("get_tagged_attention"),
      db
        .from("quotes")
        .select("id,status,source,intake_reviewed_at")
        .eq("unit_id", unit)
        .in("status", ["Draft", "Sent", "Viewed", "Agreement Pending", "Accepted"]),
      db
        .from("jobs")
        .select("id,quote_id,status,work_stage")
        .eq("is_lost",false)
        .eq("unit_id", unit),
      db
        .from("refund_requests")
        .select("id,amount,processed_amount")
        .eq("unit_id", unit)
        .in("status", ["Pending","In Review","Approved","Issued"]),
      db.rpc("support_attention"),
      db.rpc("urgent_login_attention"),
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

    const pendingRefunds = refunds.data ?? [];

    const urgentRows=classifyAttention((urgent.data?.items??[]) as AttentionRecord[]);
    const supportBadge=categoryBadge(urgentRows,"problem"),refundBadge=categoryBadge(urgentRows,"refund"),lostBadge=categoryBadge(urgentRows,"lost");
    return {
      lost:lostBadge.count,
      urgency:{notifications:supportBadge.color,refunds:refundBadge.color,lost:lostBadge.color},
      notifications: urgent.error?Number(support.data||0):supportBadge.count,
      getTagged: requestRows.length,
      quotes: openQuotes.length,
      jobs: openJobs.length,
      refunds: urgent.error?pendingRefunds.length:refundBadge.count,
    };
  } catch {
    return ZERO;
  }
}
