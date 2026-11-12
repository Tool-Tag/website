import {StatusRefresh} from "@/components/status-refresh";
import {requirePermission} from "@/lib/domain/context";
import {Heading} from "@/components/ui";
import {LostWorkspace} from "@/components/lost-workspace";
import type {LostCase} from "@/lib/domain/lost-flow";
export const dynamic="force-dynamic";
export default async function LostPage(){
 const {db,unit,access}=await requirePermission("jobs.view","pr.returns");
 const [{data,error},{data:canApprove},{data:routeStops}]=await Promise.all([
  db.rpc("lost_job_list"),
  db.rpc("refund_can_approve"),
  db.from("lost_jobs").select("id,pick_return_stops!lost_jobs_stop_id_fkey(window_start)")
   .eq("unit_id",unit).returns<{id:string;pick_return_stops:{window_start:string|null}|null}[]>(),
 ]);
 const routeStarts = new Map(routeStops?.map(row=>[row.id,row.pick_return_stops?.window_start]));
 const cases = ((data??[]) as LostCase[]).map(row=>({...row,route_window_start:routeStarts.get(row.id)}));
 const expenseOptions=access.owner?await (async()=>{
  const [accounts,categories,vendors]=await Promise.all([db.from("accounts").select("id,name").eq("unit_id",unit).eq("active",true),db.from("categories").select("id,name").eq("unit_id",unit).eq("kind","expense").eq("active",true),db.from("vendors").select("name").eq("unit_id",unit)]);
  if(accounts.error||categories.error||vendors.error)return null;
  return {accounts:(accounts.data??[]).map(a=>({value:a.id,label:a.name})),categories:(categories.data??[]).map(c=>({value:c.id,label:c.name})),vendors:(vendors.data??[]).map(v=>v.name)};
 })():null;
 if(error)throw new Error("Could not load Lost jobs");
 return <><StatusRefresh/><Heading title="Lost" subtitle="Missing items · Customer resolution"/><LostWorkspace rows={cases} canApprove={Boolean(canApprove)} expenseOptions={expenseOptions}/></>;
}
