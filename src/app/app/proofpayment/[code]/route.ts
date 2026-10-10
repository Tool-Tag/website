import {NextResponse} from "next/server";
import {cookies} from "next/headers";
import {supabase} from "@/lib/supabase/server";
import {storageAdmin} from "@/lib/storage/admin";
export const dynamic = "force-dynamic";
export const runtime = "nodejs";
const cookieName = (code: string) => `tt-proof-${code.replace(/[^a-zA-Z0-9-]/g,"")}`;
export async function POST(request: Request, {params}: {params:Promise<{code:string}>}) {
 const {code} = await params;
 if (request.headers.get("origin") !== new URL(request.url).origin) return new Response("Forbidden",{status:403});
 const form = await request.formData();
 const token = String(form.get("token") || "");
 const payment = String(form.get("payment") || "") || null;
 const db = await supabase();
 const result = await db.rpc("payment_proof_file",{p_code:code,p_payment:payment,p_token:token});
 if (result.error || !result.data) return new Response("File unavailable",{status:404});
 const target = new URL(`/app/proofpayment/${encodeURIComponent(code)}`, request.url);
 if (payment) target.searchParams.set("payment",payment);
 const response = NextResponse.redirect(target,303);
 response.cookies.set(cookieName(code),token,{httpOnly:true,secure:process.env.NODE_ENV === "production",sameSite:"strict",path:`/app/proofpayment/${encodeURIComponent(code)}`,maxAge:900});
 response.headers.set("Cache-Control","private, no-store");
 return response;
}
export async function GET(request: Request,{params}:{params:Promise<{code:string}>}) {
 const {code} = await params;
 const db = await supabase();
 const result = await db.rpc("payment_proof_file",{p_code:code,p_payment:new URL(request.url).searchParams.get("payment"),p_token:(await cookies()).get(cookieName(code))?.value || null});
 if (result.error || !result.data) return new Response("File unavailable",{status:404});
 let stored;
 try {stored = await storageAdmin().storage.from("payment-proofs").download(result.data.path);} catch {return new Response("File delivery unavailable",{status:503});}
 if (stored.error || !stored.data) return new Response("File unavailable",{status:404});
 const type = ["image/png","image/jpeg","image/webp"].includes(stored.data.type) ? stored.data.type : "application/octet-stream";
 return new Response(stored.data,{headers:{"Content-Type":type,"Content-Disposition":"inline","Cache-Control":"private, no-store","Referrer-Policy":"no-referrer","X-Content-Type-Options":"nosniff","Content-Security-Policy":"default-src 'none'; sandbox"}});
}
