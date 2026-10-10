import Link from "next/link";
import { supabase } from "@/lib/supabase/server";
import { storageStatusLabel } from "@/lib/storage/files";

export const dynamic = "force-dynamic";

function formatBytes(value?: number | null) {
  if (value === null || value === undefined) return "Size unavailable";
  if (value < 1024) return value + " B";
  if (value < 1024 * 1024) return (value / 1024).toFixed(1) + " KB";
  return (value / (1024 * 1024)).toFixed(1) + " MB";
}

export default async function CustomerDocumentPage({
  params,
}: {
  params: Promise<{ token: string; id: string }>;
}) {
  const { token, id } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("public_job_document", {
    p_token: token,
    p_document: id,
  });

  if (error || !data) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Document</p>
        <h1>This document is unavailable.</h1>
        <p>
          <Link href={`/status/${token}`}>← Back to Job Status</Link>
        </p>
      </main>
    );
  }

  const stored = data.storage_status === "stored";

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Secure Document View</p>
      <h1>{data.file_name}</h1>
      <p>
        <Link href={`/status/${token}`}>← Back to Job Status</Link>
      </p>

      <section className="panel">
        <div className="grid two">
          <div>
            <small>Document type</small>
            <p>
              <strong>{data.type}</strong>
            </p>
          </div>
          <div>
            <small>Storage status</small>
            <p>
              <strong>
                {storageStatusLabel(data.storage_status, data.storage_provider)}
              </strong>
            </p>
          </div>
          <div>
            <small>File type</small>
            <p>{data.mime_type || "Unknown"}</p>
          </div>
          <div>
            <small>File size</small>
            <p>{formatBytes(data.file_size)}</p>
          </div>
        </div>

        {stored ? (
          <p>
            <a
              className="button"
              href={`/status/${token}/documents/${id}/download`}
              target="_blank"
              rel="noreferrer"
            >
              View / download document
            </a>
          </p>
        ) : data.storage_provider === "legacy_drive" ? (
          <p className="notice">
            This historical record predates Supabase Storage. Contact ToolTag if
            you need the archived binary copy.
          </p>
        ) : data.storage_status === "Pending Drive Upload" ? (
          <p className="notice">
            Historical metadata-only record. No binary file was captured for this
            document.
          </p>
        ) : data.storage_status === "not_applicable" ? (
          <p className="notice">
            This is a structured ToolTag record and has no separate uploaded file.
          </p>
        ) : (
          <p className="notice">
            The file is not currently available for download. Contact ToolTag if
            you need assistance.
          </p>
        )}
      </section>
    </main>
  );
}
