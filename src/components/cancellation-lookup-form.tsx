"use client";

import { useActionState } from "react";
import {
  requestCancellationAccess,
  type CancelAccessState,
} from "@/app/help/cancel/actions";

const initialState: CancelAccessState = {};

export function CancellationLookupForm() {
  const [state, action, pending] = useActionState(
    requestCancellationAccess,
    initialState,
  );

  if (state.submitted) {
    return (
      <section className="panel">
        {state.matched ? (
          <p className="notice success">
            Your cancellation details have been sent to your email.
          </p>
        ) : (
          <div className="notice error">
            We couldn’t find an active ToolTag service matching the information
            provided. Please verify your details and try again, or contact ToolTag
            Support.
          </div>
        )}

        <button type="button" className="secondary" onClick={() => window.location.reload()}>
          Try Again
        </button>
      </section>
    );
  }

  return (
    <section className="panel">
      <h2>Find Your Active Services</h2>
      <p className="muted">
        Enter the same contact information used with ToolTag. We’ll check for active
        Quotes, Jobs, and Pickup & Return services.
      </p>

      <form action={action} className="stack">
        <label>
          Name
          <input name="name" required autoComplete="name" />
        </label>
        <label>
          Email
          <input name="email" type="email" required autoComplete="email" />
        </label>
        <label>
          Phone
          <input name="phone" type="tel" required autoComplete="tel" />
        </label>

        {state.error && <p className="notice error">{state.error}</p>}

        <button disabled={pending}>
          {pending ? "Checking…" : "Send Cancellation Details"}
        </button>
      </form>
    </section>
  );
}
