"use client";

import { useActionState } from "react";
import {
  registerEvidenceAction,
  type EvidenceRegistration,
} from "@/app/evidence-actions";

export function EvidenceUpload({
  config,
  button = "Upload File",
  accept,
}: {
  config: EvidenceRegistration;
  button?: string;
  accept?: string;
}) {
  const [state, action, pending] = useActionState(
    registerEvidenceAction.bind(null, config),
    {},
  );

  return (
    <form action={action} className="evidence-upload">
      <label>
        File
        <input
          name="file"
          type="file"
          required
          accept={accept}
          capture={config.photoOnly ? "environment" : undefined}
        />
      </label>

      <label>
        Visibility
        <select
          name="visibility"
          defaultValue={config.defaultVisibility ?? "internal"}
        >
          <option value="internal">Internal</option>
          <option value="customer">Customer</option>
        </select>
      </label>

      <label className="wide">
        Notes (optional)
        <textarea name="notes" rows={2} maxLength={2000} />
      </label>

      {state.error && (
        <p className="notice error wide" role="alert">
          {state.error}
        </p>
      )}

      {state.ok && (
        <p className="notice success wide" role="status">
          File stored in Supabase Storage and linked to this record.
        </p>
      )}

      <button disabled={pending}>{pending ? "Uploading…" : button}</button>
    </form>
  );
}
