import type { Metadata } from "next";
import { PublicInfoShell } from "@/components/public-info-shell";
import { HexIcon } from "@/components/hex-icon";

export const metadata: Metadata = {
  title: "Contact — ToolTag",
  alternates: { canonical: "https://tooltag.martinlab.studio/contact" },
  robots: { index: true, follow: true },
};

export default function ContactPage() {
  return <PublicInfoShell page="contact" mainClassName="public legal-page">
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
  </PublicInfoShell>;
}
