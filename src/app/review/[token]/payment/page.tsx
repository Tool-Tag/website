import { LogisticsPaymentForm } from "@/components/logistics-payment-form";
import { cardPaymentsConfigured } from "@/lib/payments";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function LogisticsPaymentPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("public_logistics_payment", {
    p_token: token,
  });

  if (error || !data) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Logistics Payment</p>
        <h1>Payment is unavailable.</h1>
        <p>Please contact ToolTag if you believe this is an error.</p>
      </main>
    );
  }

  return (
    <main className="public" lang="en">
      <p className="eyebrow">ToolTag · Logistics Payment</p>
      <h1>{data.job_code}</h1>
      <p className="muted">For {data.customer_name}</p>
      <LogisticsPaymentForm
        token={token}
        payment={data}
        cardConfigured={cardPaymentsConfigured()}
      />
      <footer className="footer">
        ToolTag is a registered DBA of Bandits of the Framing LLC.
      </footer>
    </main>
  );
}
