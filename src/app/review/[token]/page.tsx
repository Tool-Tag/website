export const maxDuration = 300;
import { supabase } from "@/lib/supabase/server";
import { Panel } from "@/components/ui";
import { QuoteScope } from "@/components/quote-scope";
import { AcceptForm } from "@/components/accept-form";
import { money } from "@/lib/domain/money";
import { PrintRecord } from "@/components/print-record";
export const dynamic = "force-dynamic";
export default async function Review({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data: q, error } = await db.rpc("public_quote", { p_token: token });
  if (error || !q)
    return (
      <main className="public">
        <h1>This link is unavailable.</h1>
        <p>It may have expired or been replaced. Please contact ToolTag.</p>
      </main>
    );
  return (
    <main className="public" lang="en">
      <p className="eyebrow">ToolTag · Your Tools. Your Mark.</p>
      <h1>{q.code}</h1>
      <p>
        For {q.customer_name} · Version {q.revision} · {q.status}
      </p>
      <p>
        Valid until:{" "}
        {new Date(q.expires_at).toLocaleString("en-US", {
          timeZone: "America/Denver",
          timeZoneName: "short",
        })}
      </p>
      {q.accepted && (
        <div className="notice success">
          <h2>You’re all set.</h2>
          <p>Quote {q.code} has been accepted.</p>
          <p>
            Your ToolTag Job number is: <strong>{q.job_code}</strong>
          </p>
          <p>
            Your confirmation copy is available here. You can print or save
            this accepted record now.
          </p>
          <p>Accepted: {new Date(q.accepted_at).toISOString()}</p>
          <PrintRecord />
        </div>
      )}
      <Panel title="Complete quote">
        <QuoteScope items={q.items} />
        <h2>Total: {money(q.total)}</h2>
        <p>{q.notes}</p>
      </Panel>
      <Panel title="Terms & Customer Agreement">
        <h3>
          {q.policy.title} · Version {q.policy.version}
        </h3>
        <div className="policy">{q.policy.content}</div>
      </Panel>
      {!q.accepted && (
        <Panel title="Review & Accept">
          <p>
            Please check spelling, designs, locations, quantities and colors.
            Contact ToolTag before accepting if anything needs to change.
          </p>
          <AcceptForm token={token} kind="review" />
        </Panel>
      )}
      {q.snapshot_hash && (
        <p className="muted quote-mark-summary">
          Record verification: {q.snapshot_hash}
        </p>
      )}
      <footer className="footer">
        ToolTag is a registered DBA of Bandits of the Framing LLC.
      </footer>
    </main>
  );
}
