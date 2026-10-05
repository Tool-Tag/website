import Link from "next/link";
import { CancellationLookupForm } from "@/components/cancellation-lookup-form";

export const dynamic = "force-dynamic";

export default function CancelServicePage() {
  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Help With</p>
      <h1>Cancel a Service</h1>
      <p className="muted">
        Request a secure link to review your active ToolTag Quotes, Jobs, and
        Pickup & Return services before cancelling.
      </p>

      <CancellationLookupForm />

      <p className="muted">
        Need help instead? <Link href="/contact">Contact ToolTag Support</Link>.
      </p>
    </main>
  );
}
