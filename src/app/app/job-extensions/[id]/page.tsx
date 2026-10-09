import Link from "next/link";
import { rows,context } from "@/lib/domain/context";
import { QuoteBuilder } from "@/components/quote-builder";
import { QuoteScope } from "@/components/quote-scope";
import { Form } from "@/components/form";
import { money } from "@/lib/domain/money";
import type { QuoteItem } from "@/lib/domain/quote-items";
export default async function ExtensionAdmin({params}:{params:Promise<{id:string}>}) {
 const {id}=await params;const {role}=await context(); const x=(await rows("job_extensions",{id}))[0];
 if(!x) return <p>Extension not found.</p>;
 const j=(await rows("jobs",{id:x.job_id}))[0];const f=(await rows("commercial_flows",{id:j.flow_id}))[0];const customer=(await rows("customers",{id:f.customer_id}))[0];
 const editable=["Requested","Draft"].includes(x.status);
 return <><Link href={`/app/jobs/${j.id}`}>← {j.code}</Link><h1>{x.code}</h1><p>{x.status}</p><p>Request: {x.customer_request}</p>
 {editable && role==="admin" ? <QuoteBuilder extensionId={x.id} customers={[{id:customer.id,name:customer.name}]} customer={customer.id} notes={x.scope || x.customer_request} initial={(x.items as QuoteItem[]).map(i=>({...i,unit_price:String(i.unit_price),engraving_text:i.engraving_text || "",width_mm:String(i.width_mm || ""),height_mm:String(i.height_mm || ""),notes:i.notes || "",paint_fill:!!i.paint_fill,colors:i.colors || 0}))}/>:<><p>{x.scope}</p><QuoteScope items={x.items}/><h2>Additional Total: {money(x.total)}</h2></>}
 {role==="admin" && ["Draft","Sent"].includes(x.status) && <Form operation="extension-send" hidden={{id:x.id}} fields={[]} button="Send Extension Proposal" back={`/app/job-extensions/${id}`}/>}
 {role==="admin" && !x.accepted_at && x.status!=="Cancelled" && <Form operation="extension-cancel" hidden={{id:x.id}} fields={[]} button="Cancel This Proposal" back={`/app/job-extensions/${id}`}/>}
 {x.accepted_at && <p>Accepted: {new Date(x.accepted_at).toLocaleString("en-US")}. Scope and price are now frozen.</p>}
 </>;
}
