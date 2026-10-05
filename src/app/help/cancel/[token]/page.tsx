import { CancellationServiceCard } from "@/components/cancellation-service-card";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function CancellationDetailsPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("cancellation_access", { p_token: token });

  if (error || !data) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Cancellation</p>
        <h1>This cancellation link is unavailable.</h1>
        <p className="muted">
          The secure link may have expired. Return to Cancel a Service to request a new one.
        </p>
      </main>
    );
  }

  const services = Array.isArray(data.services) ? data.services : [];

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Cancellation</p>
      <h1>Review Active Services</h1>
      {data.customer_name && <p className="muted">{data.customer_name}</p>}

      <section className="panel">
        <p>
          Select the Quote or Job you want to cancel. For active Jobs, ToolTag checks
          the current production stage, engraving progress, Pickup status, payments,
          and the Agreement terms before showing the cancellation result.
        </p>
      </section>

      {services.length ? (
        <div className="stack">
          {services.map((service: any) => (
            <CancellationServiceCard
              key={String(service.kind) + String(service.id)}
              token={token}
              service={service}
            />
          ))}
        </div>
      ) : (
        <section className="panel">
          <p>No active ToolTag services are available for cancellation.</p>
        </section>
      )}
    </main>
  );
}
