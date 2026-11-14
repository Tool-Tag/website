import {supportQueue} from "./support-queue";
import {workspaceJobQueues} from "./job-queues";
import {classifyAttention,categoryBadge,queueDays,urgency,type AttentionRecord,type Urgency} from "./urgent-attention";
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
      workspaceJobQueues(db, unit).catch(() => null),
      db
        .from("refund_requests")
        .select("id,amount,processed_amount")
        .eq("unit_id", unit)
        .in("status", ["Pending","In Review","Approved","Issued"]),
      supportQueue(db),
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

    const jobRows = jobs?.jobs ?? [];
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

    const pendingRefunds = refunds.data ?? [];

    const urgentRows=classifyAttention((urgent.data?.items??[]) as AttentionRecord[]);
    const now = new Date();
    const supportColors = support.open.map(row => urgency("problem", row.waiting_since ? queueDays(row.waiting_since, now, true) : 0));
    const supportColor = supportColors.includes("red") ? "red" : supportColors.includes("orange") ? "orange" : "green";
    const refundBadge=categoryBadge(urgentRows,"refund"),lostBadge=categoryBadge(urgentRows,"lost");
    return {
      lost:lostBadge.count,
      urgency:{notifications:supportColor,refunds:refundBadge.color,lost:lostBadge.color},
      notifications: support.open.length,
      getTagged: requestRows.length,
      quotes: openQuotes.length,
      jobs: jobs?.active.length ?? 0,
      refunds: urgent.error?pendingRefunds.length:refundBadge.count,
    };
  } catch {
    return ZERO;
  }
}
