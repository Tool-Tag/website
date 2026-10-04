import Link from "next/link";
import { money } from "@/lib/domain/money";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function PaymentConfirmationPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data: j, error } = await db.rpc("public_completion", {
    p_token: token,
  });

  if (error || !j || !j.acknowledgment) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Payment</p>
        <h1>This payment link is unavailable.</h1>
      </main>
    );
  }

  const payment = j.payment;
  const request = payment?.request;

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Payment Confirmation</p>
      <h1>{j.code}</h1>

      <section className="panel">
        {payment?.paid_in_full ? (
          <>
            <p className="notice success">Payment confirmed · Paid in Full</p>
            <p>
              Total paid: <strong>{money(payment.collected)}</strong>
            </p>
            <p className="muted">
              ToolTag has verified the payment and the Job is complete.
            </p>
          </>
        ) : request?.status === "Pending Verification" ? (
          <>
            <h2>Payment submitted</h2>
            <p>
              {request.method} · <strong>{money(request.amount)}</strong>
            </p>
            <p className="notice">
              Pending ToolTag verification. Your balance will not be marked paid until
              the payment is confirmed.
            </p>
            <p className="muted">
              You can return to this page later to see the updated confirmation status.
            </p>
          </>
        ) : request?.status === "Confirmed" ? (
          <>
            <p className="notice success">Payment confirmed.</p>
            <p>
              Confirmed amount: <strong>{money(request.confirmed_amount)}</strong>
            </p>
            <p>
              Remaining balance: <strong>{money(payment?.balance_due ?? 0)}</strong>
            </p>
          </>
        ) : (
          <>
            <h2>No payment submitted yet</h2>
            <Link className="button" href={`/payment/${token}`}>
              Go to Payment
            </Link>
          </>
        )}
      </section>
    </main>
  );
}
