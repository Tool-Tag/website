import {processRouteRefunds} from "@/lib/payments/route-refunds";
import { processAcceptedQueue } from "@/lib/documents/accepted-delivery";
export const maxDuration = 300;
import { dispatchQuoteMail } from "@/lib/integrations/mail-dispatch";
import { createClient } from "@supabase/supabase-js";
import { timingSafeEqual } from "node:crypto";
export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET,
    key = process.env.SUPABASE_SERVICE_ROLE_KEY,
    url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!secret || !key || !url)
    return Response.json(
      { error: "Scheduled integration is not configured" },
      { status: 503 },
    );
  const actual = Buffer.from(request.headers.get("authorization") ?? "");
  const expected = Buffer.from(`Bearer ${secret}`);
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected))
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error } = await db.rpc("run_scheduled_tasks");
  if (error)
    return Response.json({ error: "Scheduled tasks failed" }, { status: 500 });
  await processRouteRefunds(db);
  await processAcceptedQueue(db);
  return Response.json({ ok: true, messaging: await dispatchQuoteMail(db) });
}
