"use client";

import { useActionState } from "react";
import {
  requestCancellationAccess,
  type CancellationLookupState,
} from "./actions";

export function CancelLookupForm() {
  const [state, action, pending] = useActionState<
    CancellationLookupState,
    FormData
  >(requestCancellationAccess, {});

  return (
    <form action={action} className="formgrid">
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
        <input name="phone" required autoComplete="tel" />
      </label>

      {state.message && (
        <div className={state.matched ? "notice success wide" : "notice wide"}>
          {state.message}
        </div>
      )}
      {state.error && <div className="notice error wide">{state.error}</div>}

      <button disabled={pending}>
        {pending ? "Checking…" : "Find my active services"}
      </button>
    </form>
  );
}
