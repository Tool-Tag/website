import type { Metadata } from "next";
import Link from "next/link";
import { HexIcon } from "@/components/hex-icon";

export const metadata: Metadata = {
  title: "Contact — ToolTag",
  alternates: { canonical: "https://tooltag.martinlab.studio/contact" },
  robots: { index: true, follow: true },
};

export default function ContactPage() {
  return <div className="contact-site">
    <a className="contact-skip" href="#main">Skip to content</a>
    <header className="contact-header">
      <Link className="intake-brand" href="/" aria-label="ToolTag home">Tool<span>Tag</span></Link>
      <nav aria-label="Main navigation">
        <Link href="/#services">Services</Link>
        <Link href="/#how">How It Works</Link>
        <Link href="/help">Help</Link>
      </nav>
      <Link className="button gold" href="/get-tagged">Get Tagged</Link>
    </header>
    <main id="main" className="public legal-page">
      <h1>Contact ToolTag</h1>
      <div className="contact-cards">
        <section className="panel">
          <HexIcon name="mail" />
          <div><h2>Questions</h2>
            <a href="mailto:hello@martinlab.studio">hello@martinlab.studio</a></div>
        </section>
        <section className="panel">
          <HexIcon name="support" />
          <div><h2>Support</h2>
            <a href="mailto:support@martinlab.studio">support@martinlab.studio</a></div>
        </section>
      </div>
      <dl><dt>Phone</dt><dd>Coming soon</dd><dt>Address</dt><dd>Coming soon</dd></dl>
    </main>
    <footer className="contact-footer">
      <p>ToolTag is a registered DBA of Bandits of the Framing LLC.</p>
      <nav aria-label="Footer navigation">
        <Link href="/contact" aria-current="page">Contact</Link>
        <Link href="/privacy">Privacy Policy</Link>
        <Link href="/terms">Terms of Service</Link>
      </nav>
    </footer>
  </div>;
}
