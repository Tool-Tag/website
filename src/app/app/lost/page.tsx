import {StatusRefresh} from "@/components/status-refresh";
import {requirePermission} from "@/lib/domain/context";
import {Heading} from "@/components/ui";
import {LostWorkspace} from "@/components/lost-workspace";
import type {LostCase} from "@/lib/domain/lost-flow";
export const dynamic="force-dynamic";
export default async function LostPage(){
 const {db,unit,access}=await requirePermission("jobs.view","pr.returns");
 const [{data,error},{data:canApprove}]=await Promise.all([db.rpc("lost_job_list"),db.rpc("refund_can_approve")]);
 const expenseOptions=access.owner?await (async()=>{
  const [accounts,categories,vendors]=await Promise.all([db.from("accounts").select("id,name").eq("unit_id",unit).eq("active",true),db.from("categories").select("id,name").eq("unit_id",unit).eq("kind","expense").eq("active",true),db.from("vendors").select("name").eq("unit_id",unit)]);
  if(accounts.error||categories.error||vendors.error)return null;
  return {accounts:(accounts.data??[]).map(a=>({value:a.id,label:a.name})),categories:(categories.data??[]).map(c=>({value:c.id,label:c.name})),vendors:(vendors.data??[]).map(v=>v.name)};
 })():null;
 if(error)throw new Error("Could not load Lost jobs");
 return <><StatusRefresh/><Heading title="Lost" subtitle="Missing items · Customer resolution"/><LostWorkspace rows={(data??[]) as LostCase[]} canApprove={Boolean(canApprove)} expenseOptions={expenseOptions}/></>;
}
