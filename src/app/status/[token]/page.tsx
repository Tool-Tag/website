import Link from "next/link";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const standardLabels: Record<string, { title: string; description: string }> = {
  "In Process": {
    title: "In Process",
    description: "Your ToolTag Job is active and being prepared for production.",
  },
  Engraving: {
    title: "Engraving",
    description: "Your items are currently in the engraving stage.",
  },
  "Final Details": {
    title: "Final Details",
    description: "Your Job is in final adjustments and quality review.",
  },
  Completed: {
    title: "Completed",
    description: "The work is finished and ready for delivery acceptance.",
  },
};

const pickupLabels: Record<string, { title: string; description: string }> = {
  "Pickup Fee": {
    title: "Pickup Fee",
    description: "The Pickup & Return fee must be confirmed before Pickup can be scheduled.",
  },
  "Pickup Scheduled": {
    title: "Pickup Scheduled",
    description: "Your Pickup is scheduled or waiting for ToolTag scheduling confirmation.",
  },
  "Pickup In Progress": {
    title: "Pickup In Progress",
    description: "ToolTag is currently completing the Pickup route.",
  },
  "Picked Up": {
    title: "Picked Up",
    description: "Your items have been received by ToolTag.",
  },
  "In Process": {
    title: "In Process",
    description: "Your items are being prepared for engraving.",
  },
  Engraving: {
    title: "Engraving",
    description: "Your approved items are being engraved one item at a time.",
  },
  "Delivery In Progress": {
    title: "Delivery In Progress",
    description: "Production is finished and your Return delivery is being prepared.",
  },
  "Return Scheduled": {
    title: "Return Scheduled",
    description: "Your completed items have a scheduled Return window.",
  },
  "Out for Delivery": {
    title: "Out for Delivery",
    description: "ToolTag is on the way with your completed items.",
  },
  Delivered: {
    title: "Delivered",
    description: "Your items were delivered and are awaiting the remaining completion steps.",
  },
  Completed: {
    title: "Completed",
    description: "Your ToolTag Job is complete.",
  },
};

type PickupStatusData = {
  job_status?: string | null;
  work_stage?: string | null;
  items_completed?: number | string | null;
  items_total?: number | string | null;
  pickup_return?: {
    fee_status?: string | null;
    pickup_status?: string | null;
    return_status?: string | null;
  } | null;
};

function pickupCurrent(data: PickupStatusData) {
  const pr = data.pickup_return;
  if (!pr) return null;
  if (data.job_status === "Completed" || data.work_stage === "Closed") return "Completed";
  if (pr.fee_status !== "Confirmed" && !["Forfeited", "Refunded"].includes(pr.fee_status))
    return "Pickup Fee";
  if (pr.pickup_status === "Not Scheduled" || pr.pickup_status === "Scheduled")
    return "Pickup Scheduled";
  if (["En Route", "Arrived"].includes(pr.pickup_status)) return "Pickup In Progress";
  if (pr.pickup_status === "Picked Up") {
    if (data.work_stage === "Preparing") return "In Process";
    if (
      ["Engraving", "Final Evidence", "Final Details"].includes(data.work_stage) &&
      Number(data.items_completed ?? 0) < Number(data.items_total ?? 0)
    )
      return "Engraving";
    if (pr.return_status === "Delivery In Progress") return "Delivery In Progress";
    if (pr.return_status === "Scheduled") return "Return Scheduled";
    if (["En Route", "Arrived"].includes(pr.return_status)) return "Out for Delivery";
    if (pr.return_status === "Delivered") return "Delivered";
  }
  return "In Process";
}

export default async function JobStatusPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("public_job_status", { p_token: token });

  if (error || !data) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Job Status</p>
        <h1>This status link is unavailable.</h1>
      </main>
    );
  }

  const pickup = Boolean(data.pickup_return);
  const pickupSteps = [
    "Pickup Fee",
    "Pickup Scheduled",
    "Pickup In Progress",
    "Picked Up",
    "In Process",
    "Engraving",
    "Delivery In Progress",
    "Return Scheduled",
    "Out for Delivery",
    "Delivered",
    "Completed",
  ];
  const steps = pickup
    ? pickupSteps
    : Array.isArray(data.steps)
      ? data.steps
      : ["In Process", "Engraving", "Final Details", "Completed"];
  const currentKey = pickup ? pickupCurrent(data) ?? "In Process" : data.stage;
  const labels = pickup ? pickupLabels : standardLabels;
  const currentIndex = Math.max(0, steps.indexOf(currentKey));
  const current = labels[currentKey] ?? labels["In Process"];
  const total = Number(data.items_total ?? 0);
  const completed = Number(data.items_completed ?? 0);

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Job Status</p>
      <h1>{data.code}</h1>
      {data.customer_name && <p className="muted">{data.customer_name}</p>}

      {data.cancelled ? (
        <section className="panel status-card">
          <p className="status-kicker">Current status</p>
          <h2>Cancelled</h2>
          <p className="muted">
            This Job has been cancelled. Any applicable balance or refund is handled under the accepted Agreement.
          </p>
        </section>
      ) : (
        <section className="panel status-card">
          <p className="status-kicker">Current status</p>
          <h2>{current.title}</h2>
          <p className="muted">{current.description}</p>

          {currentKey === "Engraving" && total > 0 && (
            <p>
              <strong>{completed}/{total}</strong> items completed
            </p>
          )}

          <div className="status-tracker" aria-label="Job progress">
            {steps.map((step: string, index: number) => {
              const complete = index < currentIndex;
              const active = index === currentIndex;
              return (
                <div
                  key={step}
                  className={
                    active
                      ? "status-step active"
                      : complete
                        ? "status-step complete"
                        : "status-step"
                  }
                >
                  <div className="status-dot" aria-hidden="true">
                    {complete ? "✓" : index + 1}
                  </div>
                  <div>
                    <strong>{labels[step]?.title ?? step}</strong>
                    <small>{active ? "Current" : complete ? "Completed" : "Upcoming"}</small>
                  </div>
                </div>
              );
            })}
          </div>

          <p className="muted status-updated">
            Last updated: {new Date(data.updated_at).toLocaleString("en-US")}
          </p>
        </section>
      )}

      {!data.cancelled && data.job_status !== "Completed" && (
        <p>
          <Link className="button secondary" href={`/status/${token}/cancel`}>
            Cancel Service
          </Link>
        </p>
      )}

      <p className="muted">
        Keep this private link. You can return to it anytime to check your Job progress.
      </p>
    </main>
  );
}
