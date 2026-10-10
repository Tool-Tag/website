import Link from "next/link";
import { CancellationAction } from "@/components/cancellation-action";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function StatusCancellationPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("public_status_cancellation_assessment", {
    p_token: token,
  });

  if (error || !data) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Cancellation</p>
        <h1>This cancellation link is unavailable.</h1>
        <Link href={`/status/${token}`}>Back to Job Status</Link>
      </main>
    );
  }

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Cancellation</p>
      <h1>{data.job_code}</h1>

      <section className="panel">
        <h2>Review cancellation</h2>
        <p className="muted">
          ToolTag checks the current Job stage, engraving progress, payments,
          Pickup status, and the terms preserved with your accepted Agreement
          before cancellation is confirmed.
        </p>

        <CancellationAction
          token={token}
          kind="status-cancel"
          code={data.job_code}
          assessment={data.assessment}
        />
      </section>

      <p>
        <Link href={`/status/${token}`}>← Back to Job Status</Link>
      </p>
    </main>
  );
}
