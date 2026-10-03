"use client";
import { useActionState } from "react";
import { customerAction } from "@/app/actions";
export function AcceptForm({
  token,
  kind,
}: {
  token: string;
  kind: "review" | "accept" | "issue";
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
          : kind === "review"
            ? "Accept Quote & Agreement"
            : kind === "accept"
              ? "Accept Completion"
              : "Report an Issue"}
      </button>
    </form>
  );
}
