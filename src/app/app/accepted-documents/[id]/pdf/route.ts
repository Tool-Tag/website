import { supabase } from "@/lib/supabase/server";
import { inlineDisposition } from "@/lib/storage/files";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const db = await supabase();
  const {
    data: { user },
  } = await db.auth.getUser();
  if (!user) return new Response("Unauthorized", { status: 401 });

  const { id } = await params;
  const { data, error } = await db.rpc("accepted_pdf_file", { p_id: id });
  if (error || !data) return new Response("PDF unavailable", { status: 404 });

  let body: Blob;
  if (data.storage_bucket && data.storage_path) {
    const stored = await db.storage
      .from(data.storage_bucket)
      .download(data.storage_path);
    if (stored.error || !stored.data) {
      return new Response("PDF unavailable", { status: 404 });
    }
    body = stored.data;
  } else if (data.pdf) {
    body = new Blob([Uint8Array.from(Buffer.from(data.pdf, "base64"))], {
      type: "application/pdf",
    });
  } else {
    return new Response("PDF unavailable", { status: 404 });
  }

  return new Response(body, {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": inlineDisposition(data.file_name),
      "Cache-Control": "private, no-store",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
