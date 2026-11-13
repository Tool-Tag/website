import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Contact — ToolTag",
  alternates: { canonical: "https://tooltag.martinlab.studio/contact" },
  robots: { index: true, follow: true },
};

export default function ContactPage() {
  return <main className="public legal-page">
    <Link href="/">← ToolTag home</Link>
    <h1>Contact ToolTag</h1>
    <section className="panel">
      <h2>Questions</h2>
      <a href="mailto:hello@martinlab.studio">hello@martinlab.studio</a>
    </section>
    <section className="panel">
      <h2>Support</h2>
      <a href="mailto:support@martinlab.studio">support@martinlab.studio</a>
    </section>
    <dl><dt>Phone</dt><dd>Coming soon</dd><dt>Address</dt><dd>Coming soon</dd></dl>
  </main>;
}
