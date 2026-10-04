import { supabase } from "@/lib/supabase/server";
import { QuoteScope } from "@/components/quote-scope";
import { AcceptForm } from "@/components/accept-form";
import { money } from "@/lib/domain/money";
export const dynamic="force-dynamic";
export default async function Extension({params}:{params:Promise<{token:string}>}) {
 const {token}=await params;const db=await supabase();const {data:x,error}=await db.rpc("public_extension",{p_token:token});
 if(error || !x) return <main className="public"><h1>This extension is unavailable.</h1></main>;
 return <main className="public"><p className="eyebrow">ToolTag · Additional work</p><h1>{x.code}</h1><p>Original Job: {x.job_code}</p><p>{x.scope}</p><QuoteScope items={x.items}/><h2>Additional price: {money(x.total)}</h2><p>Job total including this extension: {money(x.grand_total)}</p>{x.accepted_at?<p className="notice">Extension approved. Your original Quote and Agreement remain unchanged.</p>:<AcceptForm token={token} kind="extension-accept"/>}</main>;
}
