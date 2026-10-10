import { supabase } from "@/lib/supabase/server";
import { storageAdmin } from "@/lib/storage/admin";
import { inlineDisposition } from "@/lib/storage/files";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(
  _request: Request,
  {
    params,
  }: {
    params: Promise<{ token: string; id: string }>;
  },
) {
  const { token, id } = await params;
  const db = await supabase();
  const { data: document, error } = await db.rpc("public_job_document", {
    p_token: token,
    p_document: id,
  });

  if (
    error ||
    !document ||
    document.storage_status !== "stored" ||
    !document.storage_bucket ||
    !document.storage_path
  ) {
    return new Response("File unavailable", { status: 404 });
  }

  let admin;
  try {
    admin = storageAdmin();
  } catch {
    return new Response("File delivery is not configured", { status: 503 });
  }

  const stored = await admin.storage
    .from(document.storage_bucket)
    .download(document.storage_path);
  if (stored.error || !stored.data) {
    return new Response("File unavailable", { status: 404 });
  }

  return new Response(stored.data, {
    headers: {
      "Content-Type":
        document.mime_type || stored.data.type || "application/octet-stream",
      "Content-Disposition": inlineDisposition(document.file_name),
      "Cache-Control": "private, no-store",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
