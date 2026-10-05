"use client";

import Link from "next/link";
import { useRef, useState } from "react";

type Evidence = {
  id: string;
  type?: string;
  file_name?: string;
  original_file_name?: string;
  name?: string;
  mime_type?: string | null;
  file_size?: number | null;
  storage_status?: string | null;
  storage_provider?: string | null;
  visibility?: string | null;
  folder_kind?: string | null;
  created_at?: string | null;
  notes?: string | null;
};

function formatBytes(value?: number | null) {
  if (value === null || value === undefined) return "Size unavailable";
  if (value < 1024) return value + " B";
  if (value < 1024 * 1024) return (value / 1024).toFixed(1) + " KB";
  return (value / (1024 * 1024)).toFixed(1) + " MB";
}

function storageCopy(file: Evidence) {
  if (file.storage_status === "Uploaded") {
    return "Stored file metadata is available. File delivery will stay inside ToolTag when the storage proxy is connected.";
  }
  if (file.storage_status === "Pending Drive Upload") {
    return "Metadata is preserved in ToolTag, but the binary file is not stored yet. Google Drive connection is still pending.";
  }
  return file.storage_status || "Storage status unavailable";
}

export function EvidenceGallery({
  files,
  publicView = false,
  viewerBase,
}: {
  files: Evidence[];
  publicView?: boolean;
  viewerBase?: string;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [file, setFile] = useState<Evidence | null>(null);

  return (
    <>
      <div className="evidence-grid">
        {files.map((entry) => {
          const title = entry.file_name || entry.original_file_name || entry.name || "Document";
          return (
            <button
              className="evidence-card"
              type="button"
              key={entry.id}
              onClick={() => {
                setFile(entry);
                dialog.current?.showModal();
              }}
            >
              <span className="evidence-card-icon" aria-hidden="true">
                {entry.mime_type?.startsWith("image/") ? "▧" : "▤"}
              </span>
              <span className="evidence-card-body">
                <strong>{title}</strong>
                <small>{entry.type || "Document"}</small>
                <small>{formatBytes(entry.file_size)}</small>
              </span>
              <span className="evidence-card-status">
                {entry.storage_status || "Legacy"}
              </span>
            </button>
          );
        })}
      </div>

      {!files.length && (
        <p className="muted">
          {publicView
            ? "No customer-visible documents are available yet."
            : "No evidence records yet."}
        </p>
      )}

      <dialog ref={dialog} className="quote-dialog evidence-dialog">
        {file && (
          <>
            <p className="eyebrow">{file.type || "ToolTag Document"}</p>
            <h2>{file.file_name || file.original_file_name || file.name}</h2>

            <div className="grid two">
              <div>
                <small>Storage</small>
                <p><strong>{file.storage_status || "Legacy"}</strong></p>
              </div>
              <div>
                <small>Visibility</small>
                <p><strong>{file.visibility || (publicView ? "customer" : "internal")}</strong></p>
              </div>
              <div>
                <small>Type</small>
                <p>{file.mime_type || "Unknown"}</p>
              </div>
              <div>
                <small>Size</small>
                <p>{formatBytes(file.file_size)}</p>
              </div>
            </div>

            {file.notes && <p>{file.notes}</p>}

            <p className="notice">{storageCopy(file)}</p>

            {publicView && viewerBase && (
              <p>
                <Link className="button secondary" href={viewerBase + "/" + file.id}>
                  Open ToolTag Document View
                </Link>
              </p>
            )}

            {!publicView && file.storage_provider === "legacy_drive" && (
              <p className="muted">
                This is a legacy stored record. ToolTag does not expose the raw
                Drive URL from the evidence gallery.
              </p>
            )}

            <button type="button" onClick={() => dialog.current?.close()}>
              Close
            </button>
          </>
        )}
      </dialog>
    </>
  );
}
