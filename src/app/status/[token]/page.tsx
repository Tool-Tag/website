import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const labels: Record<string, { title: string; description: string }> = {
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
  const currentIndex = Math.max(0, steps.indexOf(data.stage));
  const current = labels[data.stage] ?? labels["In Process"];

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Job Status</p>
      <h1>{data.code}</h1>
      {data.customer_name && <p className="muted">{data.customer_name}</p>}

      <section className="panel status-card">
        <p className="status-kicker">Current status</p>
        <h2>{current.title}</h2>
        <p className="muted">{current.description}</p>

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
                    {active
                      ? "Current"
                      : complete
                        ? "Completed"
                        : "Upcoming"}
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

      <p className="muted">
        Keep this private link. You can return to it anytime to check your Job progress.
      </p>
    </main>
  );
}
