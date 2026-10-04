"use client";
import { useActionState } from "react";
import { customerAction } from "@/app/actions";
export function AcceptForm({
  token,
  kind,
}: {
  token: string;
  kind: "review" | "accept" | "issue" | "work-ready" | "work-additional" | "extension-accept";
}) {
  const [state, action, pending] = useActionState(
    customerAction.bind(null, kind, token),
    {},
  );
  return (
    <form action={action} className="stack">
      {kind === "review" && (
        <>
          <label>
            Your name
            <input name="name" required autoComplete="name" />
          </label>
          <label>
            Email
            <input name="email" type="email" required autoComplete="email" />
          </label>
          <label>
            Phone
            <input name="phone" required type="tel" autoComplete="tel" />
          </label>
        </>
      )}
      {kind === "review" && (
        <>
          <label className="checkbox">
            <input type="checkbox" name="quote_confirmed" required />I have
            reviewed and approve the quote details.
          </label>
          <label className="checkbox">
            <input type="checkbox" name="agreement_confirmed" required />I have
            read and agree to ToolTag’s Terms &amp; Conditions.
          </label>
        </>
      )}
      {kind==="work-additional" && <label>What would you like to add?<textarea name="request" required maxLength={5000}/></label>}
      {kind==="extension-accept" && <><label>Your name<input name="name" required/></label><label className="checkbox"><input type="checkbox" name="confirmed" required/>I approve this extension’s additional scope and price.</label></>}
      {state.error && (
        <p role="alert" className="notice error">
          {state.error}
        </p>
      )}
      {state.ok && (
        <p role="status" className="notice success">
          Your response has been recorded.
        </p>
      )}
      <button
        disabled={pending || state.ok}
        className={kind === "issue" ? "secondary" : ""}
      >
        {pending
          ? "Saving…"
          : kind === "work-ready" ? "Ready for Delivery" : kind === "work-additional" ? "I Would Like to Add Something" : kind === "extension-accept" ? "Approve Extension" : kind === "review"
            ? "Accept Quote & Agreement"
            : kind === "accept"
              ? "I confirm receipt of my items/work"
              : "Report an Issue"}
      </button>
    </form>
  );
}
