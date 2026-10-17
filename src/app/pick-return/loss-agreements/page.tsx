import Link from "next/link";
import {requirePermission} from "@/lib/domain/context";
export const dynamic="force-dynamic";
export default async function MyDriverLossAgreements(){
 const {db,user,unit}=await requirePermission("driver.routes","pr.routes.live","pr.routes.plan");
 const {data,error}=await db.from("driver_loss_agreements").select("id,lost_id,document_version,accepted_at").eq("unit_id",unit).eq("driver_id",user.id).order("created_at",{ascending:false});
 return <section><h1>My driver loss agreements</h1>{error?<p>Driver agreements are unavailable. Please contact ToolTag.</p>:!data?.length?<p>No driver loss agreements.</p>:<ul>{data.map(row=><li key={row.id}><Link href={`/pick-return/loss-agreements/${row.id}`}>{row.lost_id} · Version {row.document_version} · {row.accepted_at?"Accepted":"Acceptance required"}</Link></li>)}</ul>}</section>;
}
