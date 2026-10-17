import type {ReactNode} from "react";
import {requirePermission} from "@/lib/domain/context";
import {financeFilters,financePage,denverDateBoundary,type FinanceSearch,type FinanceSelect} from "@/lib/domain/finance-list";
import {FinanceListFrame} from "@/components/finance-list-frame";
import {FinanceListControls,FinancePagination} from "@/components/finance-list-controls";
import {SmsCostTable,type SmsCostRow} from "@/features/sms-costs";
const selects:FinanceSelect[]=[{name:"state",label:"State",options:["Accumulating","Closed","Needs attention","Unconfirmed acceptance"]}];
export async function FinanceSmsList({header,search={}}:{header:ReactNode;search?:FinanceSearch}){
 const {db,unit}=await requirePermission("payments.view"),{values,page}=financeFilters(search,selects),path="/app/finance/sms";
 const result=await financePage<SmsCostRow>(head=>{
  let q=db.from("sms_cost_totals").select("*",{count:head?"exact":undefined,head}).eq("unit_id",unit);
  if(values.q)q=q.or(["job_code","quote_code","posting_error"].map(field=>`${field}.ilike.*${values.q}*`).join(","));
  if(values.state==="Needs attention")q=q.not("posting_error","is",null);
  if(values.state==="Unconfirmed acceptance")q=q.is("posting_error",null).gt("acceptance_unknown_count",0);
  if(values.state==="Accumulating"||values.state==="Closed"){q=q.is("posting_error",null).eq("acceptance_unknown_count",0);q=values.state==="Closed"?q.not("closed_at","is",null):q.is("closed_at",null);}
  if(values.from)q=q.gte("updated_at",denverDateBoundary(values.from));if(values.to)q=q.lt("updated_at",denverDateBoundary(values.to,true));
  return q.order("updated_at",{ascending:false}).order("id",{ascending:false});
 },page);
 return <FinanceListFrame header={header} controls={<FinanceListControls path={path} title="SMS Costs" placeholder="Quote, Job or posting error" values={values} selects={selects}/>}><SmsCostTable data={result.rows}/><FinancePagination path={path} values={values} {...result}/></FinanceListFrame>;
}
