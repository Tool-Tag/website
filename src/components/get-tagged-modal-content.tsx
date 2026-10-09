"use client";

import { useEffect, useState } from "react";
import { GetTaggedForm } from "@/components/get-tagged-form";

const CLOSE_MESSAGE = "tooltag:get-tagged-close";

function requestClose() {
  window.parent.postMessage({ type: CLOSE_MESSAGE }, window.location.origin);
}

export function GetTaggedModalContent() {
  const [reference, setReference] = useState<string | null>(null);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") requestClose();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  if (reference !== null) {
    return (
      <main className="intake-modal-page intake-modal-success">
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
        <button type="button" onClick={requestClose}>
          Close
        </button>
      </main>
    );
  }

  return (
    <main className="intake-modal-page">
      <p className="muted intake-modal-intro">
        Tell us what you have and how you want to make it yours.
      </p>
      <GetTaggedForm modal onSuccess={setReference} />
    </main>
  );
}
