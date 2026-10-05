import { CancelLookupForm } from "./cancel-lookup-form";

export const dynamic = "force-dynamic";

export default function CancelServicePage() {
  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Help With</p>
      <h1>Cancel a Service</h1>
      <p className="muted">
        Enter the same contact information used with ToolTag. If active services
        are found, cancellation details will be sent to your email.
      </p>

      <section className="panel">
        <CancelLookupForm />
      </section>
    </main>
  );
}
