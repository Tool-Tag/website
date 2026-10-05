import type { Metadata } from "next";
import Link from "next/link";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Request Received | ToolTag",
  robots: { index: false, follow: false },
};

export default async function GetTaggedThanksPage({
  searchParams,
}: {
  searchParams: Promise<{ reference?: string }>;
}) {
  const { reference } = await searchParams;

  return (
    <main className="intake-page">
      <Link className="intake-brand" href="/">
        Tool<span>Tag</span>
      </Link>

      <p className="eyebrow">REQUEST RECEIVED</p>
      <h1>We got it.</h1>

      <section className="panel">
        {reference && (
          <p>
            Request reference: <strong>{reference}</strong>
          </p>
        )}
        <p>
          Your request is now pending ToolTag review. We will review the items,
          engraving details, service method, compatibility, and scheduling before
          preparing a Quote.
        </p>
        <p className="muted">
          Submitting a Get Tagged request does not approve a price, authorize work,
          or create a Job. A Job is created only after the Quote and ToolTag
          Agreement are accepted.
        </p>
      </section>

      <Link className="button" href="/">
        Back to ToolTag
      </Link>

      <footer>ToolTag is a registered DBA of Bandits of the Framing LLC.</footer>
    </main>
  );
}
