"use client";

import type { EvidenceRegistration } from "@/app/evidence-actions";
import { EvidenceUpload } from "@/components/evidence-upload";

export function EvidenceCapture({
  config,
  photosOnly=false,
}: {
  config: Omit<EvidenceRegistration, "photoOnly">;
  photosOnly?:boolean;
}) {
  return (
    <div className="evidence-capture">
      <div>
        <h4>Photo</h4>
        <EvidenceUpload
          config={{ ...config, photoOnly: true }}
          button="Upload"
          accept="image/*"
        />
      </div>

      {!photosOnly&&<details>
        <summary>Upload File</summary>
        <EvidenceUpload
          config={{ ...config, photoOnly: false }}
          button="Upload File"
        />
      </details>}
    </div>
  );
}
