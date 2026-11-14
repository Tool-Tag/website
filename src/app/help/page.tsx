import { HexIcon } from "@/components/hex-icon";
import { PublicInfoShell } from "@/components/public-info-shell";
import {HelpContactCards} from "@/components/help-contact-cards";
import Link from "next/link";
import { GetTaggedModalLink } from "@/components/get-tagged-modal-link";

export const dynamic = "force-dynamic";

export default function HelpPage() {
  return (
    <PublicInfoShell page="help" mainClassName="public">
      <p className="eyebrow">ToolTag · Help</p>
      <h1>What do you need help with?</h1>
      <p className="muted">
        Use the option that matches your current ToolTag service.
      </p>

      <div className="contact-cards">
        <HelpContactCards />

        <section className="panel">
          <HexIcon name="cancel" />
          <div>
            <h2>Cancel a Service</h2>
            <p className="muted">
              Review eligible active Quotes, Jobs, and Pick up & Delivery services before
              confirming a cancellation.
            </p>
            <Link className="button" href="/help/cancel">
              Cancel a Service
            </Link>
          </div>
        </section>

        <section className="panel">
          <HexIcon name="request" />
          <div>
            <h2>Start a Request</h2>
            <p className="muted">
              Send ToolTag the items, marking details, and service method you want us
              to review.
            </p>
            <GetTaggedModalLink className="button secondary">
              Get Tagged
            </GetTaggedModalLink>
          </div>
        </section>

        <section className="panel">
          <HexIcon name="job" />
          <div>
            <h2>Existing Job</h2>
            <p className="muted">
              Use the private Job Status link ToolTag sent you. That page shows live
              progress, documents, Pick up & Delivery details, and cancellation options
              when the service is still eligible.
            </p>
          </div>
        </section>
      </div>
    </PublicInfoShell>
  );
}
