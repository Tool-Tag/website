import type {ReactNode} from "react";
import {requirePermission} from "@/lib/domain/context";
import {financeFilters,financePage,denverDateBoundary,type FinanceSearch,type FinanceSelect} from "@/lib/domain/finance-list";
import {FinanceListFrame} from "@/components/finance-list-frame";
import {FinanceListControls,FinancePagination} from "@/components/finance-list-controls";
import {RefundsPanel} from "@/features/refunds";
import type {RefundJob} from "@/components/refund-forms";
import {Panel,Empty} from "@/components/ui";
const selects:FinanceSelect[]=[{name:"method",label:"Method",options:["Zelle","Venmo","Card","Bank Transfer","Check"]},{name:"reason",label:"Reason",options:["Customer cancellation","ToolTag error","Driver-down $5","Driver-down $10","Damage","Other"]}];
export async function FinanceRefundsList({header,search={}}:{header:ReactNode;search?:FinanceSearch}){
 const {db,unit}=await requirePermission("payments.refund","payments.view"),{values,page}=financeFilters(search,selects),path="/app/finance/refunds";
 let matchingJobs:string[]=[];
 if(values.q){const {data,error}=await db.rpc("refund_job_choices");if(error)throw new Error("Unable to search refund jobs.");const text=values.q.toLocaleLowerCase("en-US");matchingJobs=((data??[]) as RefundJob[]).filter(j=>j.code.toLocaleLowerCase("en-US").includes(text)||j.customer_name?.toLocaleLowerCase("en-US").includes(text)).map(j=>j.id).filter(id=>/^[a-f0-9-]{36}$/i.test(id));}
 const result=await financePage(head=>{
  let q=db.from("refund_requests").select("id",{count:head?"exact":undefined,head}).eq("unit_id",unit).eq("status","Approved");
  if(values.q){const parts=["reason","notes","reference"].map(field=>`${field}.ilike.*${values.q}*`);if(matchingJobs.length)parts.push(`job_id.in.(${matchingJobs.join(",")})`);q=q.or(parts.join(","));}
  if(values.method)q=q.eq("method",values.method);if(values.reason)q=q.eq("reason",values.reason);
  if(values.from)q=q.gte("requested_at",denverDateBoundary(values.from));if(values.to)q=q.lt("requested_at",denverDateBoundary(values.to,true));
  return q.order("requested_at",{ascending:false}).order("id",{ascending:false});
 },page);
 return <FinanceListFrame header={header} controls={<FinanceListControls path={path} title="Refunds" placeholder="Customer, Job, reason or reference" values={values} selects={selects}/>}>
 <p>Approved refunds only. Execute refunds manually here; case management remains in Refunds.</p>
 {result.rows.length?<RefundsPanel view="execution" requestIds={result.rows.map(r=>r.id)}/>:<Panel><Empty>No approved refunds match these filters.</Empty></Panel>}
 <FinancePagination path={path} values={values} {...result}/></FinanceListFrame>;
}
