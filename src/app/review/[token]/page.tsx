export const maxDuration = 300;
import Link from "next/link";
import { supabase } from "@/lib/supabase/server";
import { Panel } from "@/components/ui";
import { QuoteScope } from "@/components/quote-scope";
import { ReviewAcceptanceFlow } from "@/components/review-acceptance-flow";
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

  const logisticsStatus = q.logistics?.payment_status as string | undefined;
  const paymentOutstanding =
    q.accepted &&
    q.logistics?.option &&
    !["paid_confirmed", "not_applicable"].includes(logisticsStatus ?? "");

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

      {q.accepted ? (
        <>
          <div className={paymentOutstanding ? "notice" : "notice success"}>
            <h2>{paymentOutstanding ? "Acceptance recorded." : "You’re all set."}</h2>
            <p>Quote {q.code} has been accepted.</p>
            <p>
              Your ToolTag Job number is: <strong>{q.job_code}</strong>
            </p>
            {paymentOutstanding ? (
              <>
                <p>
                  Your logistics selection is locked. The logistics fee must be
                  confirmed before ToolTag can begin the applicable
                  scheduling/work stage.
                </p>
                {logisticsStatus === "pending_verification" ? (
                  <p>
                    We&apos;ll verify your payment within 24 hours and notify you
                    by email.
                  </p>
                ) : (
                  <Link className="button" href={`/review/${token}/payment`}>
                    Continue to Logistics Payment
                  </Link>
                )}
              </>
            ) : (
              <p>Your accepted record is ready to print or save.</p>
            )}
            <p>Accepted: {new Date(q.accepted_at).toISOString()}</p>
            <PrintRecord />
          </div>

          <Panel title="Complete quote">
            <QuoteScope items={q.items} />
            <h2>Total: {money(q.total)}</h2>
            {q.notes && <p>{q.notes}</p>}
          </Panel>

          {q.logistics?.option && (
            <Panel title="Logistics">
              <p>
                <strong>{q.logistics.option.name}</strong> ·{" "}
                {q.logistics.option.fee
                  ? money(q.logistics.option.fee)
                  : "Free"}
              </p>
              <p>{q.logistics.option.description}</p>
              {q.logistics.pickup_address && (
                <p>Pickup: {q.logistics.pickup_address}</p>
              )}
              {q.logistics.saturday_date && (
                <p>
                  Requested Pickup date:{" "}
                  {new Date(
                    q.logistics.saturday_date + "T12:00:00",
                  ).toLocaleDateString("en-US")}{" "}
                  · 8:00 AM–12:00 PM
                </p>
              )}
              {q.logistics.delivery_address && (
                <p>Delivery: {q.logistics.delivery_address}</p>
              )}
            </Panel>
          )}

          <Panel title="Terms & Customer Agreement">
            <h3>
              {q.policy.title} · Version {q.policy.version}
            </h3>
            <div className="policy">{q.policy.content}</div>
          </Panel>
        </>
      ) : (
        <ReviewAcceptanceFlow
          token={token}
          items={q.items}
          baseTotal={q.total}
          notes={q.notes}
          policy={q.policy}
          logistics={q.logistics}
        />
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
