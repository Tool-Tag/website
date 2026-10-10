import { context } from "@/lib/domain/context";
import { inlineDisposition } from "@/lib/storage/files";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;
  const { db, unit } = await context();
  const { data: document, error } = await db
    .from("documents")
    .select(
      "file_name,mime_type,storage_status,storage_bucket,storage_path",
    )
    .eq("id", id)
    .eq("unit_id", unit)
    .single();

  if (
    error ||
    !document ||
    document.storage_status !== "stored" ||
    !document.storage_bucket ||
    !document.storage_path
  ) {
    return new Response("File unavailable", { status: 404 });
  }

  const stored = await db.storage
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
