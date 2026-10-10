import {ReturnChoice} from "@/components/return-choice";
import {PaymentForm} from "@/components/payment-form";
import {cardPaymentsConfigured} from "@/lib/payments";
import {RouteCalendar} from "@/components/route-calendar";
import {StatusRefresh} from "@/components/status-refresh";
import {StatusTimeline} from "@/components/status-timeline";
import {denverDateTime, denverTime} from "@/lib/domain/time";
import Link from "next/link";
import { CancellationBalanceForm } from "@/components/cancellation-balance-form";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { StatusCancellation } from "@/components/status-cancellation";
import { money } from "@/lib/domain/money";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const labels: Record<string, { title: string; description: string }> = {
  "Pending Delivery": {title:"Pending Delivery",description:"Confirm payment or choose an available delivery option. Cash must be selected before the final cutoff."},
  "Shop Pickup": {title:"Shop Pickup",description:"Your items are held at the shop. Wait for ToolTag pickup instructions."},
  "Pickup Fee": {
    title: "Pickup Fee",
    description: "The Pickup & Return fee must be paid and confirmed before scheduling.",
  },
  "Pickup Scheduled": {
    title: "Pickup Scheduled",
    description: "Your items are waiting for the scheduled ToolTag Pickup.",
  },
  "Pickup In Progress": {
    title: "Pickup In Progress",
    description: "ToolTag is currently working through the Pickup route.",
  },
  "Picked Up": {
    title: "Picked Up",
    description: "Your items have been received by ToolTag.",
  },
  "In Process": {
    title: "In Process",
    description: "Your ToolTag Job is active and being prepared for production.",
  },
  Engraving: {
    title: "Engraving",
    description: "Your items are currently being engraved.",
  },
  "Final Details": {
    title: "Final Details",
    description: "Your Job is in final review.",
  },
  "Delivery In Progress": {
    title: "Delivery In Progress",
    description: "Your completed items have entered the Return delivery process.",
  },
  "Return Scheduled": {
    title: "Return Scheduled",
    description: "Your Return delivery date and time window have been scheduled.",
  },
  "Out for Delivery": {
    title: "Out for Delivery",
    description: "ToolTag is on the way with your completed items.",
  },
  Delivered: {
    title: "Delivered",
    description: "Your items have been delivered and delivery evidence has been recorded.",
  },
  Cancelled: {
    title: "Cancelled",
    description: "This ToolTag service has been cancelled.",
  },
  "Cancellation Balance": {
    title: "Cancellation Balance",
    description: "A cancellation balance must be confirmed before ToolTag can return items already in its possession.",
  },
  Completed: {
    title: "Completed",
    description: "Your ToolTag Job has been completed.",
  },
};

function formatWindow(start?: string | null, end?: string | null) {
  if (!start || !end) return null;
  return `${denverDateTime(start)} – ${denverTime(end)}`;
}

export default async function JobStatusPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("public_job_status", {
    p_token: token,
  });

  if (error || !data) {
    return (
      <main className="public"><StatusRefresh />
        <p className="eyebrow">ToolTag · Job Status</p>
        <h1>This status link is unavailable.</h1>
      </main>
    );
  }

  const cancellationFinance = data.cancelled
    ? (
        await db.rpc("public_status_cancellation_finance", {
          p_token: token,
        })
      ).data
    : null;

  const { data: customerDocuments } = await db.rpc("public_job_documents", {
    p_token: token,
  });

  const visibleDocuments = Array.isArray(customerDocuments)
    ? customerDocuments
    : [];

  const steps = Array.isArray(data.steps)
    ? data.steps
    : ["In Process", "Engraving", "Final Details", "Completed"];
  const activeStage = data.tracking_stage ?? data.stage ?? "In Process";
  const current = labels[activeStage] ?? labels["In Process"];
  const pickup = data.pickup_return;
  const itemsTotal = Number(data.items_total ?? 0);
  const itemsCompleted = Number(data.items_completed ?? 0);
  const itemsStarted = Number(data.items_started ?? 0);

  return (
    <main className="public"><StatusRefresh />
      <p className="eyebrow">ToolTag · Job Status</p>
      <h1>{data.code}</h1>
      {data.customer_name && <p className="muted">{data.customer_name}</p>}

      {data.cancelled && (
        <p className="notice error">
          <strong>THIS SERVICE HAS BEEN CANCELLED.</strong>
        </p>
      )}

      <section className="panel status-card">
        <p className="status-kicker">Current status</p>
        <h2>{current.title}</h2>
        <p className="muted">{current.description}</p>

        {itemsTotal > 0 && (
          <div className="status-progress-summary">
            <strong>
              {itemsCompleted}/{itemsTotal} items finished
            </strong>
            {itemsStarted > itemsCompleted && (
              <span className="muted">
                {itemsStarted}/{itemsTotal} items started or finished
              </span>
            )}
          </div>
        )}

        {pickup && (
          <div className="status-logistics">
            <div>
              <small>Pickup</small>
              <strong>{pickup.pickup_status}</strong>
              {formatWindow(pickup.pickup_window_start, pickup.pickup_window_end) && (
                <span>{formatWindow(pickup.pickup_window_start, pickup.pickup_window_end)}</span>
              )}
              {pickup.pickup_eta && (
                <span>
                  ETA: {denverDateTime(pickup.pickup_eta)}
                </span>
              )}
            </div>
            <div>
              <small>Return</small>
              <strong>{pickup.return_status}</strong>
              {formatWindow(pickup.return_window_start, pickup.return_window_end) && (
                <span>{formatWindow(pickup.return_window_start, pickup.return_window_end)}</span>
              )}
              {pickup.return_eta && (
                <span>
                  ETA: {denverDateTime(pickup.return_eta)}
                </span>
              )}
            </div>
          </div>
        )}

        {pickup?.return_window_start && pickup.delivery_payment_status !== "Shop Pickup" && !["Delivered","En Route","Arrived","Cancelled"].includes(pickup.return_status) && <details><summary>Reschedule Return</summary><RouteCalendar job={data.id} leg="Return" token={token} /></details>}
        {["Not Scheduled","Scheduled"].includes(pickup?.pickup_status) && <details><summary>Reschedule Pickup</summary><RouteCalendar job={data.id} leg="Pickup" token={token} /></details>}
        <StatusTimeline steps={steps} current={activeStage} updated={data.updated_at} finished={itemsCompleted} total={itemsTotal} />
      </section>

      {pickup?.delivery_attempts === 1 && pickup.delivery_payment_status !== "Shop Pickup" && !pickup.return_window_start && <ReturnChoice token={token} job={data.id} fee={Number(data.second_return_fee)} chosen={Boolean(data.second_return_chosen)} />}
      {pickup?.production_ready_at && !pickup.returned_at && Number(data.payment?.balance_due || 0)>0 && <PaymentForm token={token} balanceDue={data.payment.balance_due} zelleEmail={data.payment.methods?.zelle_email} venmoHandle={data.payment.methods?.venmo_handle} cardConfigured={cardPaymentsConfigured()} routePayment />}
      {Array.isArray(data.payment_proofs) && data.payment_proofs.length>0 && <section className="panel"><h2>Payment proofs</h2>{data.payment_proofs.map((proof:{id:string;submitted_at:string})=><form key={proof.id} method="post" action={`/app/proofpayment/${encodeURIComponent(data.code)}`}><input type="hidden" name="token" value={token}/><input type="hidden" name="payment" value={proof.id}/><button>View payment proof · {denverDateTime(proof.submitted_at)}</button></form>)}</section>}
      <section className="panel status-help-panel">
        <p className="status-kicker">Help With</p>
        <h2>This Service</h2>
        <p className="muted">
          Need help with this ToolTag service? Use the options below without
          leaving your Job Status page.
        </p>
        <div className="status-help-actions">
          {!data.cancelled && data.job_status !== "Completed" && (
            <StatusCancellation token={token} />
          )}
          <Link className="button secondary" href="/help">
            Help Center
          </Link>
        </div>
      </section>

      {visibleDocuments.length > 0 && (
        <section className="panel">
          <p className="status-kicker">Documents & Evidence</p>
          <h2>Your ToolTag files</h2>
          <p className="muted">
            Only records marked customer-visible are shown here. Storage provider
            details and raw storage links are never exposed.
          </p>
          <EvidenceGallery
            files={visibleDocuments}
            publicView
            viewerBase={`/status/${token}/documents`}
          />
        </section>
      )}

      {data.cancelled && cancellationFinance && (
        <>
          {Number(cancellationFinance.refund_eligible_amount ?? 0) > 0 && (
            <section className="panel">
              <p className="status-kicker">Refund</p>
              <h2>{money(cancellationFinance.refund_eligible_amount)}</h2>
              {cancellationFinance.refund_status === "Completed" ? (
                <p className="notice success">
                  ToolTag has processed this refund. Your bank or payment provider
                  may require additional time before the funds appear.
                </p>
              ) : (
                <p className="notice">
                  Refund pending. Approved refunds are generally processed within
                  5–7 business days after ToolTag confirms the refund.
                </p>
              )}
            </section>
          )}

          {Number(cancellationFinance.balance_remaining ?? 0) > 0 &&
            cancellationFinance.payment?.status === "Pending Verification" && (
              <section className="panel">
                <p className="status-kicker">Cancellation balance</p>
                <h2>{money(cancellationFinance.balance_remaining)} pending verification</h2>
                <p className="notice">
                  ToolTag received your {cancellationFinance.payment.method} payment
                  submission. If ToolTag has your items, Return remains on hold until
                  the payment is verified.
                </p>
              </section>
            )}

          {Number(cancellationFinance.balance_remaining ?? 0) > 0 &&
            cancellationFinance.payment?.status !== "Pending Verification" && (
              <CancellationBalanceForm
                token={token}
                amount={cancellationFinance.balance_remaining}
                zelleEmail={cancellationFinance.zelle_email}
                venmoHandle={cancellationFinance.venmo_handle}
              />
            )}

          {Number(cancellationFinance.amount_due ?? 0) > 0 &&
            Number(cancellationFinance.balance_remaining ?? 0) <= 0 && (
              <p className="notice success">
                Cancellation balance paid and confirmed.
                {pickup?.pickup_status === "Picked Up"
                  ? " ToolTag can continue the Return process."
                  : ""}
              </p>
            )}
        </>
      )}

      <p className="muted">
        Keep this private link. You can return to it anytime to check your Job progress.
      </p>
    </main>
  );
}
