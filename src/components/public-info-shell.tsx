import Link from "next/link";
import type { ReactNode } from "react";

export function PublicInfoShell({ page, mainClassName, children }: { page: "contact" | "help"; mainClassName: string; children: ReactNode }) {
  return <div className="contact-site">
    <a className="contact-skip" href="#main">Skip to content</a>
    <header className="contact-header">
      <Link className="intake-brand" href="/" aria-label="ToolTag home">Tool<span>Tag</span></Link>
      <nav aria-label="Main navigation">
        <Link href="/#services">Services</Link>
        <Link href="/#how">How It Works</Link>
        <Link href="/help" aria-current={page === "help" ? "page" : undefined}>Help</Link>
      </nav>
      <Link className="button gold" href="/get-tagged">Get Tagged</Link>
    </header>
    <main id="main" className={mainClassName}>{children}</main>
    <footer className="contact-footer">
      <p>ToolTag is a registered DBA of Bandits of the Framing LLC.</p>
      <nav aria-label="Footer navigation">
        <Link href="/contact" aria-current={page === "contact" ? "page" : undefined}>Contact</Link>
        <Link href="/privacy">Privacy Policy</Link>
        <Link href="/terms">Terms of Service</Link>
      </nav>
    </footer>
  </div>;
}
