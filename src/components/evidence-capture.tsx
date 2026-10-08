"use client";

import type { EvidenceRegistration } from "@/app/evidence-actions";
import { EvidenceUpload } from "@/components/evidence-upload";

export function EvidenceCapture({
  config,
}: {
  config: Omit<EvidenceRegistration, "photoOnly">;
}) {
  return (
    <div className="evidence-capture">
      <div>
        <h4>Photo</h4>
        <EvidenceUpload
          config={{ ...config, photoOnly: true }}
          button="Upload Photo"
          accept="image/*"
        />
      </div>

      <details>
        <summary>Upload File</summary>
        <EvidenceUpload
          config={{ ...config, photoOnly: false }}
          button="Upload File"
        />
      </details>
    </div>
  );
}
