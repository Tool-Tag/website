import { PickupFeeForm } from "@/components/pickup-fee-form";
import { money } from "@/lib/domain/money";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function PickupFeePage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("public_pickup_fee", { p_token: token });

  if (error || !data) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Pickup & Return</p>
        <h1>This Pickup payment link is unavailable.</h1>
      </main>
    );
  }

  const status = String(data.fee_status ?? "Required");

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Pickup & Return</p>
      <h1>{data.job_code}</h1>
      <p className="muted">
        Pickup scheduling is unlocked only after the Pickup Service Fee is confirmed.
      </p>

      {status === "Confirmed" ? (
        <section className="panel">
          <h2>Pickup Fee Confirmed</h2>
          <p className="notice success">
            Your {money(data.amount)} Pickup Service Fee has been confirmed.
          </p>
          <p className="muted">
            {data.scheduler_enabled
              ? "Pickup scheduling is available for this Job."
              : "Automatic customer scheduling is not enabled yet. ToolTag will coordinate your Pickup date and time."}
          </p>
        </section>
      ) : status === "Pending Verification" ? (
        <section className="panel">
          <h2>Payment Pending Verification</h2>
          <p>
            Pickup Service Fee: <strong>{money(data.amount)}</strong>
          </p>
          <p className="notice">
            ToolTag received your payment submission. Pickup scheduling remains locked
            until the payment is verified.
          </p>
        </section>
      ) : (
        <PickupFeeForm
          token={token}
          amount={data.amount}
          zelleEmail={data.zelle_email}
          venmoHandle={data.venmo_handle}
          termsVersion={data.terms_version}
        />
      )}

      <section className="panel">
        <h2>Pickup & Return Disclaimer</h2>
        <p>
          Pickup is normally scheduled on Saturdays between 8:00 AM and 12:00 PM.
          Completed items are normally returned on Sunday between approximately
          4:00 PM and 6:00 PM, depending on workload. Processing may extend up to
          the following Sunday when necessary.
        </p>
        <p>
          Changes or cancellations must be received no later than Friday at
          6:00 PM before the scheduled Saturday Pickup for the Pickup Service Fee
          to remain eligible for refund. After that deadline, or if ToolTag arrives
          and the items are unavailable for Pickup, the Pickup Service Fee is
          non-refundable.
        </p>
        <p>
          On Return day, monitor the phone number and email provided to ToolTag.
          Items will not be left unattended unless you expressly authorize it. If
          unattended delivery is authorized, ToolTag will record delivery evidence.
          Once the items are delivered to the authorized location and evidence is
          recorded, ToolTag is not responsible for subsequent theft or loss except
          where applicable law provides otherwise.
        </p>
        <p className="muted">
          These Pickup & Return terms are part of the ToolTag Agreement accepted for
          this Job. Terms version: {data.terms_version ?? "2.0"}.
        </p>
      </section>
    </main>
  );
}
