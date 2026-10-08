import Link from "next/link";
import { supabase } from "@/lib/supabase/server";

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
            <p><strong>{data.type}</strong></p>
          </div>
          <div>
            <small>Storage status</small>
            <p><strong>{data.storage_status}</strong></p>
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

        {data.storage_status === "Pending Drive Upload" ? (
          <p className="notice">
            ToolTag has preserved this document&apos;s metadata and relationship to
            your Job. The binary file is not stored yet because Google Drive has
            not been connected.
          </p>
        ) : (
          <p className="notice">
            This secure ToolTag route is ready to become the file-delivery layer.
            Raw storage-provider links are intentionally not exposed.
          </p>
        )}
      </section>
    </main>
  );
}
