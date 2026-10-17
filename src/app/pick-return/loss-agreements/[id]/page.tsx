import {requirePermission} from "@/lib/domain/context";
import {DriverLossAcceptance} from "@/components/driver-loss-acceptance";
import {denverDateTime} from "@/lib/domain/time";
export const dynamic="force-dynamic";
export default async function DriverLossAgreementPage({params}:{params:Promise<{id:string}>}){
 const {id}=await params;const {db}=await requirePermission("driver.routes","pr.routes.live","pr.routes.plan");
 const {data,error}=await db.rpc("driver_loss_agreement",{p_id:id,p_accept:false});
 if(error||!data)return <section><h1>Driver agreement unavailable</h1><p>Sign in with the named driver account or contact ToolTag.</p></section>;
 return <section><h1>Driver Loss Agreement</h1><p>Version {data.document_version} · {data.cost_final?"Final documented cost":"Initial notice"}</p><article className="panel" style={{whiteSpace:"pre-wrap"}}>{data.document_text}</article>{data.accepted_at?<p>Accepted: {denverDateTime(data.accepted_at)}</p>:data.can_accept?<DriverLossAcceptance id={id}/>:<p>Only the named driver can accept this agreement.</p>}<p>{data.eligible?"Eligible for new route assignments.":"New assignments are blocked while an agreement, Owner decision, or ban is outstanding."}</p></section>;
}
