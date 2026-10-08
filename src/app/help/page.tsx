import Link from "next/link";

export const dynamic = "force-dynamic";

export default function HelpPage() {
  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Help</p>
      <h1>What do you need help with?</h1>
      <p className="muted">
        Use the option that matches your current ToolTag service.
      </p>

      <section className="panel">
        <h2>Cancel a Service</h2>
        <p className="muted">
          Review eligible active Quotes, Jobs, and Pickup & Return services before
          confirming a cancellation.
        </p>
        <Link className="button" href="/help/cancel">
          Cancel a Service
        </Link>
      </section>

      <section className="panel">
        <h2>Start a Request</h2>
        <p className="muted">
          Send ToolTag the items, marking details, and service method you want us
          to review.
        </p>
        <Link className="button secondary" href="/get-tagged">
          Get Tagged
        </Link>
      </section>

      <section className="panel">
        <h2>Existing Job</h2>
        <p className="muted">
          Use the private Job Status link ToolTag sent you. That page shows live
          progress, documents, Pickup & Return details, and cancellation options
          when the service is still eligible.
        </p>
      </section>
    </main>
  );
}
