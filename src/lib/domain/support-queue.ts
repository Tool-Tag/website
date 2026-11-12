import { cache } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import { isPresentationTest } from "./presentation";
import { supportMailboxMatches } from "./support-view";

type SupportCase = {
  id: string; status: string; origin: string; channel: string; mailbox: string;
  subject: string; case_code: string | null; sender_name: string; sender_email: string;
  job_id: string | null; updated_at: string; last_message: string | null;
  last_message_at: string | null; waiting_since: string | null;
};

export const supportQueue = cache(async (db: SupabaseClient) => {
  const { data, error } = await db.rpc("support_cases");
  if (error) return { cases: [], open: [], support: 0, questions: 0, error };
  const cases = ((data ?? []) as SupportCase[]).filter(row =>
    (supportMailboxMatches(row.mailbox, false) || supportMailboxMatches(row.mailbox, true)) &&
    !isPresentationTest(JSON.stringify(row)));
  const open = cases.filter(row => row.status !== "Closed");
  return {
    cases, open, error: null,
    support: open.filter(row => supportMailboxMatches(row.mailbox, false)).length,
    questions: open.filter(row => supportMailboxMatches(row.mailbox, true)).length,
  };
});
