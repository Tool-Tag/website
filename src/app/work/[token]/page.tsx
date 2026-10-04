import { supabase } from "@/lib/supabase/server";
import { QuoteScope } from "@/components/quote-scope";
import { AcceptForm } from "@/components/accept-form";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { money } from "@/lib/domain/money";
import type { QuoteItem } from "@/lib/domain/quote-items";
export const dynamic="force-dynamic";
export default async function WorkReview({params}:{params:Promise<{token:string}>}) {
 const {token}=await params;const db=await supabase();const {data:j,error}=await db.rpc("public_work_review",{p_token:token});
 if(error || !j) return <main className="public"><h1>This review link is unavailable.</h1></main>;
 return <main className="public"><p className="eyebrow">ToolTag · Work review</p><h1>{j.code}</h1><p>{j.customer_name}</p><QuoteScope items={j.original_quote.items}/>{j.extensions.map((x:{code:string;items:QuoteItem[]})=><section key={x.code}><h2>{x.code}</h2><QuoteScope items={x.items}/></section>)}<h2>Grand total: {money(j.totals.grand_total)}</h2><h2>Completed work</h2><EvidenceGallery files={j.evidence} publicView/>
 {j.response_at ? <p className="notice">Your response has been recorded: {j.response==="ready"?"Ready for Delivery":"Additional work requested"}.</p>:j.status==="Ready for Delivery"?<div className="grid two"><AcceptForm token={token} kind="work-ready"/><AcceptForm token={token} kind="work-additional"/></div>:<p>Job status: {j.status}</p>}
 <p className="muted">This review is separate from payment and confirmation of physical delivery.</p></main>;
}
