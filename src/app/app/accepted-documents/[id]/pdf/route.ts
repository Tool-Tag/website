import { supabase } from "@/lib/supabase/server";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(_request: Request, {params}:{params:Promise<{id:string}>}) {
  const db = await supabase();
  const {data:{user}} = await db.auth.getUser();
  if (!user) return new Response("Unauthorized",{status:401});
  const {id} = await params;
  const {data,error} = await db.rpc("accepted_pdf_file",{p_id:id});
  if (error || !data) return new Response("PDF unavailable",{status:404});
  return new Response(new Uint8Array(Buffer.from(data.pdf,"base64")),{headers:{
    "Content-Type":"application/pdf","Content-Disposition":`inline; filename="${data.file_name}"`,
    "Cache-Control":"private, no-store","Referrer-Policy":"no-referrer","X-Content-Type-Options":"nosniff",
  }});
}
