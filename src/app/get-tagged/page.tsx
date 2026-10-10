import type { Metadata } from "next";
import Link from "next/link";
import { GetTaggedForm } from "@/components/get-tagged-form";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Get Tagged | ToolTag",
  description: "Request personalized engraving for your tools and equipment.",
  robots: { index: false, follow: false },
};

export default function GetTaggedPage() {
  return (
    <main className="intake-page">
      <Link className="intake-brand" href="/">
        Tool<span>Tag</span>
      </Link>
      <p>
        <Link href="/">← Back to home</Link>
      </p>
      <p className="eyebrow">YOUR TOOLS. YOUR MARK.</p>
      <h1>Get Tagged.</h1>
      <p className="muted">
        Tell us what you have and how you want to make it yours.
      </p>
      <GetTaggedForm />
      <footer>ToolTag is a registered DBA of Bandits of the Framing LLC.</footer>
    </main>
  );
}
