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
          ToolTag Pickup service is normally scheduled on Saturdays between
          <strong> 8:00 AM and 12:00 PM</strong>.
        </p>
        <p>
          Items picked up on Saturday are generally expected to be completed and
          returned on Sunday between approximately <strong>4:00 PM and 6:00 PM</strong>,
          depending on workload and the approved scope. Some Jobs may require
          additional processing time, and the Return may extend up to the following
          Sunday.
        </p>
        <p>
          If an unexpected delay, service issue, or schedule change affects the
          expected Return, ToolTag will notify you by email and, when SMS
          notifications are available, may also notify you by text message.
        </p>
        <p>
          Weekday Pickup or Return service may be available during afternoon hours
          and may include an additional service charge. Special scheduling requests
          must be confirmed by ToolTag before service.
        </p>
        <p>
          A scheduled Pickup may be changed or cancelled without forfeiting the
          Pickup Service Fee only if ToolTag receives the change or cancellation no
          later than <strong>Friday at 6:00 PM</strong> before the scheduled Saturday
          Pickup. After that deadline, the Pickup Service Fee is
          <strong> non-refundable</strong>.
        </p>
        <p>
          If ToolTag arrives at the scheduled Pickup location and the customer, an
          authorized person, or the items are unavailable, the Pickup Service Fee
          remains due and is <strong>non-refundable</strong>. A new Pickup appointment
          may require another Pickup Service Fee.
        </p>
        <p>
          On the scheduled Return day, monitor the phone number and email address
          provided to ToolTag so delivery can be coordinated.
        </p>
        <p>
          ToolTag will not leave customer items unattended at a door, porch, or
          other location unless the customer expressly authorizes unattended
          delivery. When unattended delivery is authorized, ToolTag may photograph
          or otherwise document where the items were left. Once the items have been
          delivered to the customer&apos;s authorized location and delivery evidence
          has been recorded, ToolTag is not responsible for subsequent theft, loss,
          or unauthorized removal except where applicable law provides otherwise.
        </p>
        <p className="muted">
          These Pickup & Return Service Terms are part of the ToolTag Agreement
          accepted for this Job and remain visible here as a service disclaimer.
          Terms version: {data.terms_version ?? "2.0"}.
        </p>
      </section>
    </main>
  );
}
