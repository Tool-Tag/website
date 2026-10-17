import {supabase} from "@/lib/supabase/server";
import {money} from "@/lib/domain/money";
import {LostResolutionChoice} from "@/components/lost-resolution-choice";
export const dynamic="force-dynamic";
export default async function LostResolutionPage({params}:{params:Promise<{token:string}>}) {
 const {token}=await params;
 if(!/^[a-f0-9]{64}$/.test(token))return <main className="public"><h1>Resolution link unavailable</h1></main>;
 const db=await supabase();const {data,error}=await db.rpc("public_lost_resolution",{p_token:token,p_choice:null});
 if(error||!data)return <main className="public"><h1>Resolution link unavailable</h1><p>Please contact ToolTag for assistance.</p></main>;
 return <main className="public"><h1>We are sorry about your missing items</h1><section className="panel"><h2>{data.job_code}</h2><p>We apologize for the inconvenience and want to make this right. Please choose your preferred resolution below.</p><ul>{(data.items as {sequence:number;article:string}[]).map(i=><li key={i.sequence}>{i.sequence}. {i.article}</li>)}</ul><p>Total market value: <strong>{money(data.market_value)}</strong></p>{data.choice?<p role="status">Your choice: <strong>{data.choice}</strong>. {data.status==="History"?"This resolution is completed.":"Our team will coordinate the next steps with you."}</p>:<LostResolutionChoice token={token}/>}</section></main>;
}
