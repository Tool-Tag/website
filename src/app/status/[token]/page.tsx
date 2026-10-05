import { StatusCancellation } from "@/components/status-cancellation";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const labels: Record<string, { title: string; description: string }> = {
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
  Completed: {
    title: "Completed",
    description: "Your ToolTag Job has been completed.",
  },
};

function formatWindow(start?: string | null, end?: string | null) {
  if (!start || !end) return null;
  return `${new Date(start).toLocaleString("en-US")} – ${new Date(end).toLocaleTimeString("en-US", {
    hour: "numeric",
    minute: "2-digit",
  })}`;
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
      <main className="public">
        <p className="eyebrow">ToolTag · Job Status</p>
        <h1>This status link is unavailable.</h1>
      </main>
    );
  }

  const steps = Array.isArray(data.steps)
    ? data.steps
    : ["In Process", "Engraving", "Final Details", "Completed"];
  const activeStage = data.tracking_stage ?? data.stage ?? "In Process";
  const locatedIndex = steps.indexOf(activeStage);
  const currentIndex = locatedIndex >= 0 ? locatedIndex : 0;
  const current = labels[activeStage] ?? labels["In Process"];
  const pickup = data.pickup_return;
  const itemsTotal = Number(data.items_total ?? 0);
  const itemsCompleted = Number(data.items_completed ?? 0);
  const itemsStarted = Number(data.items_started ?? 0);

  return (
    <main className="public">
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
                  ETA: {new Date(pickup.pickup_eta).toLocaleString("en-US")}
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
                  ETA: {new Date(pickup.return_eta).toLocaleString("en-US")}
                </span>
              )}
            </div>
          </div>
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
                  <small>
                    {active ? "Current" : complete ? "Completed" : "Upcoming"}
                  </small>
                </div>
              </div>
            );
          })}
        </div>

        <p className="muted status-updated">
          Last updated: {new Date(data.updated_at).toLocaleString("en-US")}
        </p>
      </section>

      {!data.cancelled && data.job_status !== "Completed" && (
        <StatusCancellation token={token} />
      )}

      <p className="muted">
        Keep this private link. You can return to it anytime to check your Job progress.
      </p>
    </main>
  );
}
