import { QuoteScope } from "@/components/quote-scope";
import type { QuoteItem } from "@/lib/domain/quote-items";
import { supabase } from "@/lib/supabase/server";
import { AcceptForm } from "@/components/accept-form";
import { PaymentForm } from "@/components/payment-form";
import { money } from "@/lib/domain/money";

export const dynamic = "force-dynamic";

export default async function Completion({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data: j, error } = await db.rpc("public_completion", {
    p_token: token,
  });

  if (error || !j)
    return (
      <main className="public">
        <h1>This link is unavailable.</h1>
      </main>
    );

  const payment = j.payment;
  const request = payment?.request;

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Delivery</p>
      <h1>{j.code}</h1>

      {j.original_quote && <QuoteScope items={j.original_quote.items} />}

      {j.extensions?.map((x: { code: string; items: QuoteItem[] }) => (
        <section key={x.code}>
          <h2>{x.code}</h2>
          <QuoteScope items={x.items} />
        </section>
      ))}

      {!j.acknowledgment && (
        <p>
          I confirm that I received the items/work associated with this ToolTag Job.
          This confirms receipt only. It does not confirm payment or waive your legal rights.
        </p>
      )}

      {j.status === "Delivered – Pending Customer Acceptance" ? (
        <div className="grid two">
          <AcceptForm token={token} kind="accept" />
          <AcceptForm token={token} kind="issue" />
        </div>
      ) : j.acknowledgment ? (
        <>
          <p className="notice success">
            Delivery confirmed. Your payment is handled separately from the delivery acknowledgment.
          </p>

          {payment?.paid_in_full ? (
            <section className="panel">
              <h2>Payment</h2>
              <p className="notice success">Paid in Full</p>
              <p>
                Total: {money(payment.grand_total)} · Paid: {money(payment.collected)}
              </p>
            </section>
          ) : request?.status === "Pending Verification" ? (
            <section className="panel">
              <h2>Payment</h2>
              <p>
                {request.method} payment submitted for <strong>{money(request.amount)}</strong>.
              </p>
              <p className="notice">
                Pending ToolTag verification. Your balance will update only after the payment is confirmed.
              </p>
            </section>
          ) : (
            <PaymentForm
              token={token}
              balanceDue={payment?.balance_due ?? 0}
              zelleEmail={payment?.methods?.zelle_email}
              venmoHandle={payment?.methods?.venmo_handle}
            />
          )}
        </>
      ) : (
        <p className="notice">{j.reason ?? j.status}</p>
      )}
    </main>
  );
}
