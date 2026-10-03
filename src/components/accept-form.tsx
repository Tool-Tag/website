"use client";
import { useActionState } from "react";
import { customerAction } from "@/app/actions";
export function AcceptForm({
  token,
  kind,
}: {
  token: string;
  kind: "quote" | "agreement" | "accept" | "issue";
}) {
  const [state, action, pending] = useActionState(
    customerAction.bind(null, kind, token),
    {},
  );
  return (
    <form action={action} className="stack">
      {kind === "agreement" && (
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
      {["quote", "agreement"].includes(kind) && (
        <label className="checkbox">
          <input type="checkbox" name="confirmed" required />
          {kind === "quote"
            ? "I reviewed and approve the items, text, design instructions, dimensions and price shown above."
            : "I have read and accept the exact agreement version shown above."}
        </label>
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
          : kind === "quote"
            ? "Accept Quote"
            : kind === "agreement"
              ? "Accept Agreement"
              : kind === "accept"
                ? "Accept Completion"
                : "Report an Issue"}
      </button>
    </form>
  );
}
