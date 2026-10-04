import Link from "next/link";
import { PaymentForm } from "@/components/payment-form";
import { money } from "@/lib/domain/money";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function PaymentPage({
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
        <h1>Payment is not available yet.</h1>
      </main>
    );
  }

  const payment = j.payment;
  const request = payment?.request;

  if (payment?.paid_in_full || request?.status === "Pending Verification") {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Payment</p>
        <h1>{j.code}</h1>
        <section className="panel">
          <h2>Payment</h2>
          <p>
            Balance due: <strong>{money(payment?.balance_due ?? 0)}</strong>
          </p>
          <Link className="button" href={`/payment/${token}/confirmation`}>
            View Payment Confirmation
          </Link>
        </section>
      </main>
    );
  }

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Payment</p>
      <h1>{j.code}</h1>
      <p className="muted">
        Delivery has been accepted. Choose how you would like to pay.
      </p>
      <PaymentForm
        token={token}
        balanceDue={payment?.balance_due ?? 0}
        zelleEmail={payment?.methods?.zelle_email}
        venmoHandle={payment?.methods?.venmo_handle}
      />
    </main>
  );
}
