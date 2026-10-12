import type { Metadata } from "next";
import Link from "next/link";
export const metadata: Metadata = {title: "Terms of Service — ToolTag", alternates: {canonical: "https://tooltag.martinlab.studio/terms"}, robots: {index: true, follow: true}};
export default function Page() { return <main className="public legal-page" lang="en"><Link href="/">← ToolTag home</Link><article><h1>{"Terms of Service — ToolTag"}</h1><p><strong>Last updated: October 12, 2026</strong></p><p>{"These Terms govern your use of tooltag.martinlab.studio and the laser tool-marking services by Bandits of the Framing LLC (dba ToolTag), Utah, USA."}</p><section><h2>{"1. Services"}</h2><p>{"Laser engraving, marking, and labeling for tools, including optional pickup and delivery logistics. Details in the quote flow and Service Agreement."}</p></section>
<section><h2>{"2. Quotes and orders"}</h2><p>{"Quotes are estimates. Order confirmed upon quote acceptance and required steps completion."}</p></section>
<section><h2>{"3. Payments"}</h2><p>{"Payment methods as shown at checkout. Utah sales tax included in totals where required."}</p></section>
<section><h2>{"4. Scheduling, pickup, and delivery"}</h2><p>{"Per the Service Agreement. Time windows are estimates."}</p></section>
<section><h2>{"5. SMS notifications (transactional)"}</h2><p>{"If you opt in: stage updates, pickup/delivery alerts, confirmations, payment reminders. Consent is optional, not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply STOP to opt out, HELP for help. Mobile info not shared with third parties for marketing (see Privacy Policy)."}</p></section>
<section><h2>{"6. Acceptable use"}</h2><p>{"Do not misuse the Site or submit unlawful content."}</p></section>
<section><h2>{"7. Intellectual property"}</h2><p>{"Site content owned by us or licensors. Your designs remain yours."}</p></section>
<section><h2>{"8. Limitation of liability"}</h2><p>{"Liability limited to amount paid for the order giving rise to the claim, to the maximum extent permitted by law."}</p></section>
<section><h2>{"9. Changes"}</h2><p>{"We may update these Terms; apply to orders placed after the update."}</p></section>
<section><h2>{"10. Governing law"}</h2><p>{"Law of the State of Utah, USA."}</p></section>
<section><h2>{"11. Contact"}</h2><p>{"Through the Site or support email on our contact page."}</p></section>
</article><footer className="footer"><nav aria-label="Legal"><Link href="/privacy">Privacy Policy</Link>{" · "}<Link href="/terms">Terms of Service</Link></nav><p>ToolTag is a registered DBA of Bandits of the Framing LLC.</p></footer></main>; }
