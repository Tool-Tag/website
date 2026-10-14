import {requirePermission} from "@/lib/domain/context";
import {Heading,Panel} from "@/components/ui";
import {denverDateTime} from "@/lib/domain/time";
type LostJob={id:string;job:string;customer:string;phone:string;driver:string;driver_id:string|null;driver_email:string|null;route_date:string;explanation:string;reported_at:string;items:{id:string;article:string;sequence:number}[]};
export const dynamic="force-dynamic";
export default async function LostPage(){
 const {db}=await requirePermission("jobs.view","pr.returns");
 const {data,error}=await db.rpc("lost_job_list");if(error)throw new Error("Could not load Lost jobs");
 const list=(data??[]) as LostJob[];
 return <><Heading title="Lost" subtitle="Missing items · Owner follow-up"/><Panel>{!list.length&&<p>No lost jobs reported.</p>}{list.map(row=><article className="panel" key={row.id}><h2>{row.job} · {row.customer}</h2><p>Customer phone: {row.phone||"Not provided"}</p><p>Driver: {row.driver}{row.driver_id?` · ${row.driver_id}`:""}</p><p>Driver contact: {row.driver_email||"Not provided"}</p><p>Route: {row.route_date} · Reported: {denverDateTime(row.reported_at)}</p><ul>{row.items.map(i=><li key={i.id}>{i.sequence}. {i.article}</li>)}</ul><p>{row.explanation}</p></article>)}</Panel></>;
}
