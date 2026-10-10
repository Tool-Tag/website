"use client";

import Link from "next/link";
import { useRef, useState } from "react";
import {
  legacyDriveUrl,
  storageStatusLabel,
} from "@/lib/storage/files";

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
  storage_bucket?: string | null;
  storage_path?: string | null;
  drive_file_id?: string | null;
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
  if (file.storage_status === "stored") {
    return "Binary file stored privately in Supabase Storage.";
  }
  if (file.storage_status === "failed") {
    return "The Storage upload failed. Upload the file again before continuing the workflow.";
  }
  if (file.storage_provider === "legacy_drive") {
    return "Historical Drive reference retained read-only. New files are stored in Supabase Storage.";
  }
  if (file.storage_status === "Pending Drive Upload") {
    return "Historical metadata-only record. No binary file was captured in Supabase Storage.";
  }
  if (file.storage_status === "not_applicable") {
    return "This is a structured ToolTag record and has no separate uploaded binary.";
  }
  return "Storage status: " + storageStatusLabel(file.storage_status, file.storage_provider);
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
          const title =
            entry.file_name || entry.original_file_name || entry.name || "Document";
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
                {storageStatusLabel(entry.storage_status, entry.storage_provider)}
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
                <p>
                  <strong>
                    {storageStatusLabel(file.storage_status, file.storage_provider)}
                  </strong>
                </p>
              </div>
              <div>
                <small>Visibility</small>
                <p>
                  <strong>
                    {file.visibility || (publicView ? "customer" : "internal")}
                  </strong>
                </p>
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
                <Link
                  className="button secondary"
                  href={viewerBase + "/" + file.id}
                >
                  Open ToolTag Document View
                </Link>
              </p>
            )}

            {!publicView && file.storage_status === "stored" && (
              <p>
                <a
                  className="button secondary"
                  href={`/app/documents/${file.id}/download`}
                  target="_blank"
                  rel="noreferrer"
                >
                  View / download file
                </a>
              </p>
            )}

            {!publicView &&
              file.storage_provider === "legacy_drive" &&
              file.drive_file_id && (
                <p>
                  <a
                    className="button secondary"
                    href={legacyDriveUrl(file.drive_file_id)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Open legacy Drive reference ↗
                  </a>
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
