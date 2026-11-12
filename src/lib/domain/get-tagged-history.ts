import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { storageAdmin } from "@/lib/storage/admin";

export type GetTaggedListRow = {
  id: string;
  reference: string;
  name: string;
  service_method?: string | null;
  created_at: string;
  request_status: string;
  matching: string;
  quote_id?: string | null;
  quote_only?: boolean;
};

const PAGE_SIZE = 500;

export async function getTaggedHistory(db: SupabaseClient, unit: string) {
  const [rejected, attention] = await Promise.all([
    db.rpc("get_tagged_history"),
    db.rpc("get_tagged_attention"),
  ]);
  if (rejected.error || attention.error) throw new Error("Could not load request history.");

  const rows = (rejected.data ?? []) as GetTaggedListRow[];
  const pending = (attention.data ?? []) as GetTaggedListRow[];
  const excluded = new Set([...rows, ...pending].map(row => row.id));

  // The inbox notifications provide IDs only. Read each receipt through the
  // existing request RPC using the current staff session and its permissions.
  const index = storageAdmin();
  const ids = new Set<string>();
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const { data, error } = await index.from("notifications").select("entity_id")
      .eq("unit_id", unit).eq("event", "GET_TAGGED_REQUEST")
      .order("id").range(offset, offset + PAGE_SIZE - 1);
    if (error) throw new Error("Could not load approved requests.");
    for (const row of data) if (row.entity_id && !excluded.has(row.entity_id)) ids.add(row.entity_id);
    if (data.length < PAGE_SIZE) break;
  }

  const requestIds = [...ids];
  for (let offset = 0; offset < requestIds.length; offset += 16) {
    const batch = await Promise.all(requestIds.slice(offset, offset + 16).map(id =>
      db.rpc("get_get_tagged_request", { p_id: id })));
    for (const { data, error } of batch) {
      if (error?.message === "Request not found") continue;
      if (error) throw new Error("Could not load approved requests.");
      if (!data || !["Approved", "Converted"].includes(data.request_status)) continue;
      rows.push({
        id: data.id, reference: data.reference, name: data.details?.contact?.name || "Customer",
        service_method: data.details?.service?.method, created_at: data.created_at,
        request_status: data.request_status, matching: data.matching, quote_id: data.quote_id,
      });
    }
  }

  // Legacy intake drafts without a notification can still be opened from
  // History through their original quote, using only staff-visible data.
  const linkedQuotes = new Set([...rows, ...pending].map(row => row.quote_id));
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const { data, error } = await db.from("quotes")
      .select("id,code,created_at,status,name:intake_details->contact->>name,service_method:intake_details->service->>method")
      .eq("unit_id", unit).eq("source", "public_get_tagged").eq("revision", 1)
      .order("id").range(offset, offset + PAGE_SIZE - 1)
      .returns<{ id: string; code: string; created_at: string; status: string; name: string | null; service_method: string | null }[]>();
    if (error) throw new Error("Could not load intake quotes.");
    for (const quote of data) {
      if (linkedQuotes.has(quote.id) || quote.status === "Rejected") continue;
      rows.push({
        id: quote.id, reference: quote.code, name: quote.name || "Customer",
        service_method: quote.service_method, created_at: quote.created_at,
        request_status: "Converted", matching: "", quote_id: quote.id, quote_only: true,
      });
    }
    if (data.length < PAGE_SIZE) break;
  }
  return rows.sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || a.id.localeCompare(b.id));
}
