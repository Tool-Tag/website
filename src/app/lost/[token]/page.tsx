import {supabase} from "@/lib/supabase/server";
import {money} from "@/lib/domain/money";
import {LostResolutionChoice} from "@/components/lost-resolution-choice";
import {LostPaymentForm,LostReplacementChoice} from "@/components/lost-customer-fulfillment";
export const dynamic="force-dynamic";
export default async function LostResolutionPage({params}:{params:Promise<{token:string}>}) {
 const {token}=await params;
 if(!/^[a-f0-9]{64}$/.test(token))return <main className="public"><h1>Resolution link unavailable</h1></main>;
 const db=await supabase();const {data,error}=await db.rpc("public_lost_resolution",{p_token:token,p_choice:null});
 if(error||!data)return <main className="public"><h1>Resolution link unavailable</h1><p>Please contact ToolTag for assistance.</p></main>;
 return <main className="public"><h1>We are sorry about your missing items</h1><section className="panel"><h2>{data.job_code}</h2><p>We apologize for the inconvenience and want to make this right. Please choose your preferred resolution below.</p><ul>{(data.items as {sequence:number;article:string}[]).map(i=><li key={i.sequence}>{i.sequence}. {i.article}</li>)}</ul><p>Total market value: <strong>{money(data.market_value)}</strong></p>{data.choice?<p role="status">Your choice: <strong>{data.choice}</strong>. {data.ready_at?"Your replacement is ready.":data.status==="History"?"Your refund has been processed. Please check your refund confirmation email.":"Our team will coordinate the next steps with you."}</p>:<LostResolutionChoice token={token}/>}{data.choice==="Refund money"&&!data.payment_details_submitted&&data.status!=="History"&&<LostPaymentForm token={token} original={data.original_method}/>} {data.choice==="Refund money"&&data.payment_details_submitted&&<p role="status">Your payment details have been received securely. Your refund is being reviewed.</p>}{data.ready_at&&!data.fulfillment_choice&&<LostReplacementChoice token={token} address={data.address??""}/>} {data.fulfillment_choice&&<p role="status">Your choice: {data.fulfillment_choice}.{data.delivery&&<> Free priority delivery: {data.delivery.status}{data.delivery.route_date&&<> · {data.delivery.route_date}</>}</>}</p>}</section></main>;
}
