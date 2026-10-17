import {StatusRefresh} from "@/components/status-refresh";
import {requirePermission} from "@/lib/domain/context";
import {Heading} from "@/components/ui";
import {LostWorkspace} from "@/components/lost-workspace";
import type {LostCase} from "@/lib/domain/lost-flow";
export const dynamic="force-dynamic";
export default async function LostPage(){
 const {db}=await requirePermission("jobs.view","pr.returns");
 const [{data,error},{data:canApprove}]=await Promise.all([db.rpc("lost_job_list"),db.rpc("refund_can_approve")]);
 if(error)throw new Error("Could not load Lost jobs");
 return <><StatusRefresh/><Heading title="Lost" subtitle="Missing items · Customer resolution"/><LostWorkspace rows={(data??[]) as LostCase[]} canApprove={Boolean(canApprove)}/></>;
}
