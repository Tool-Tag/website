import { StatusSmsOptIn } from "@/components/sms-consent";
import {CustomerArrivalBanner,CustomerDeliveryAcknowledgment} from "@/components/customer-arrival-banner";
import {CustomerRouteTimeline} from "@/components/customer-route-timeline";
import {DriverIncidentChoice} from "@/components/driver-incident-choice";
import {PickupMissChoice} from "@/components/pickup-miss-choice";
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
  "Pending Delivery": {title:"Pending Delivery",description:"Confirm your payment or choose a delivery option. Select Cash before the final cutoff."},
  "Shop Pickup": {title:"Shop Pickup",description:"Your items remain at the shop. Wait for ToolTag pickup instructions."},
  "Pickup Fee": {
    title: "Pickup Fee",
    description: "The logistics fee must be paid and confirmed before scheduling.",
  },
  "Pickup Scheduled": {
    title: "Pickup Scheduled",
    description: "Your items are awaiting the scheduled ToolTag Pickup.",
  },
  "Pickup In Progress": {
    title: "Pickup In Progress",
    description: "ToolTag is working through the Pickup route.",
  },
  "Picked Up": {
    title: "Picked Up",
    description: "ToolTag collected your items.",
  },
  "Received at Shop": {title:"Received at Shop",description:"The shop is verifying your items against the receiving list and photos before production."},
  "In Process": {
    title: "In Process",
    description: "Your job is being prepared for production.",
  },
  Engraving: {
    title: "Engraving",
    description: "We are engraving your items.",
  },
  "Final Details": {
    title: "Final Details",
    description: "Your job is in final review.",
  },
  "Delivery In Progress": {
    title: "Delivery In Progress",
    description: "Your finished items are being prepared for delivery.",
  },
  "Return Scheduled": {
    title: "Return Scheduled",
    description: "Your delivery date and window are scheduled.",
  },
  "Out for Delivery": {
    title: "Out for Delivery",
    description: "ToolTag is on the way with your finished items.",
  },
  Delivered: {
    title: "Delivered",
    description: "Your items were delivered and evidence was recorded.",
  },
  Cancelled: {
    title: "Cancelled",
    description: "This ToolTag service was cancelled.",
  },
  "Cancellation Balance": {
    title: "Cancellation Balance",
    description: "The cancellation balance must be confirmed before returning items held by ToolTag.",
  },
  Completed: {
    title: "Completed",
    description: "Your ToolTag job is complete.",
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
        <p className="eyebrow">ToolTag · Tracking</p>
        <h1>This tracking link is unavailable.</h1>
      </main>
    );
  }

  const {data:pickupMissed}=await db.rpc("pickup_miss_state",{p_job:data.id,p_token:token});
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
  const deliveryWaiting=pickup?.pickup_status==="Picked Up"&&(!pickup.production_ready_at||!["Pickup & Delivery","Drop-off + Delivery"].includes(pickup.service_method));
  const {data:driverIncident,error:incidentError}=await db.rpc("driver_incident_context",{p_job:data.id,p_token:token});
  if(incidentError)throw new Error("Could not load route update");
  const {data:customerRoutes,error:routesError}=await db.rpc("customer_route_tracking",{p_job:data.id,p_token:token});
  if(routesError)throw new Error("Could not load route tracking");
  const {data:liveChannel}=await db.rpc("status_live_channel",{p_token:token});
  const {data:arrival}=await db.rpc("customer_arrival_context",{p_token:token});
  const arrivedLeg=arrival?.leg as "Pickup"|"Return"|undefined;
  const itemsTotal = Number(data.items_total ?? 0);
  const itemsCompleted = Number(data.items_completed ?? 0);
  const itemsStarted = Number(data.items_started ?? 0);

  const {data: smsConsent} = await db.rpc("sms_consent_state", {p_token:token,p_scope:"status"});
  return (
    <main className="public"><StatusRefresh channels={liveChannel?[liveChannel]:[]} />
      {arrivedLeg&&<CustomerArrivalBanner token={token} leg={arrivedLeg} responded={Boolean(arrival?.responded)} />}
      <p className="eyebrow">ToolTag · Tracking</p>
      <h1>{data.code}</h1>
      {data.customer_name && <p className="muted">{data.customer_name}</p>}

      {data.cancelled && (
        <p className="notice error">
          <strong>THIS SERVICE HAS BEEN CANCELLED.</strong>
        </p>
      )}

      <section className="panel status-card">
        <p className="status-kicker">Current status</p>
        <h2>{activeStage}</h2>
        <p className="muted">{current.description}</p>

        {itemsTotal > 0 && (
          <div className="status-progress-summary">
            <strong>
              {itemsCompleted}/{itemsTotal} pieces finished
            </strong>
            {itemsStarted > itemsCompleted && (
              <span className="muted">
                {itemsStarted}/{itemsTotal} pieces started or finished
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
                  Scheduled time: {denverDateTime(pickup.pickup_eta)}
                </span>
              )}
            </div>
            <div aria-disabled={deliveryWaiting} className={deliveryWaiting?"delivery-waiting":""}>
              {deliveryWaiting&&<p>Delivery — Waiting for delivery details, if applicable.</p>}
              <small>Delivery</small>
              <strong>{pickup.return_status}</strong>
              {formatWindow(pickup.return_window_start, pickup.return_window_end) && (
                <span>{formatWindow(pickup.return_window_start, pickup.return_window_end)}</span>
              )}

              {pickup.return_eta && (
                <span>
                  Scheduled time: {denverDateTime(pickup.return_eta)}
                </span>
              )}
            </div>
          </div>
        )}

        {pickup?.return_window_start && !pickup.return_reservation_stop_id && pickup.delivery_payment_status !== "Shop Pickup" && !["Delivered","En Route","Arrived","Cancelled"].includes(pickup.return_status) && <details><summary>Reschedule delivery</summary><RouteCalendar job={data.id} leg="Return" token={token} locale="en" /></details>}
        {["Not Scheduled","Scheduled"].includes(pickup?.pickup_status) && <details><summary>Reschedule Pickup</summary><RouteCalendar job={data.id} leg="Pickup" token={token} locale="en" /></details>}
        <StatusTimeline steps={steps} current={activeStage} updated={data.updated_at} finished={itemsCompleted} total={itemsTotal} />
      </section>

      {Array.isArray(customerRoutes)&&customerRoutes.length>0&&<CustomerRouteTimeline routes={customerRoutes} />}

      {data.job_status==="Delivered – Pending Customer Acceptance"&&<CustomerDeliveryAcknowledgment token={token} />}
      {pickup?.delivery_payment_method==="Cash"&&!pickup.returned_at&&Number(data.payment?.balance_due)>0&&<section className="panel"><h2>Please make your cash payment of {money(data.payment.balance_due)}</h2><p>Do not pay more than this amount.</p><p className="notice error">Tipping the driver is optional.</p></section>}
      {driverIncident && <DriverIncidentChoice job={data.id} token={token} data={driverIncident} />}
      {pickupMissed && !data.cancelled && <PickupMissChoice job={data.id} token={token} />}
      {pickup?.delivery_attempts === 1 && pickup.delivery_payment_status !== "Shop Pickup" && pickup.return_reservation_stop_id && <ReturnChoice token={token} job={data.id} fee={Number(data.second_return_fee)} chosen={Boolean(data.second_return_chosen)} />}
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
        Save this private link. Return anytime to check your job progress.
      </p>
      <StatusSmsOptIn token={token} phone={smsConsent?.phone} granted={smsConsent?.granted} />
    </main>
  );
}
