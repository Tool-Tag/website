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

      <p className="notice wide evidence-storage-note">
        Google Drive is not connected yet. ToolTag will save the evidence record,
        SHA-256 fingerprint, file metadata, visibility, and workflow relationship.
        The binary file itself is <strong>not stored yet</strong> and will remain
        marked <strong>Pending Drive Upload</strong>.
      </p>

      {state.error && (
        <p className="notice error wide" role="alert">
          {state.error}
        </p>
      )}

      {state.ok && (
        <p className="notice success wide">
          Evidence registered. {state.warning}
        </p>
      )}

      <button disabled={pending}>{pending ? "Registering…" : button}</button>
    </form>
  );
}
