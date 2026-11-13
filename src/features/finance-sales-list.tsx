import {denverCalendarDate,denverDateTime} from "@/lib/domain/time";
import type {ReactNode} from "react";
import Link from "next/link";
import {context} from "@/lib/domain/context";
import {financeFilters,financePage,type FinanceSearch,type FinanceSelect} from "@/lib/domain/finance-list";
import {FinanceListFrame} from "@/components/finance-list-frame";
import {FinanceListControls,FinancePagination} from "@/components/finance-list-controls";
import {Panel,Table,Badge,Empty} from "@/components/ui";
import {money} from "@/lib/domain/money";
const selects:FinanceSelect[]=[{name:"status",label:"Status",options:["Open","Partially Paid","Paid","Partially Refunded","Refunded","Cancelled"]}];
export async function FinanceSalesList({header,search={}}:{header:ReactNode;search?:FinanceSearch}){
 const {db,unit}=await context(),{values,page}=financeFilters(search,selects),path="/app/finance/sales";
 const result=await financePage(head=>{
  let q=db.from("sale_balances").select("*",{count:head?"exact":undefined,head}).eq("unit_id",unit);
  if(values.q)q=q.ilike("code",`%${values.q}%`);if(values.status)q=q.eq("status",values.status);
  if(values.from)q=q.gte("transaction_date",values.from);if(values.to)q=q.lte("transaction_date",values.to);
  return q.order("transaction_date",{ascending:false}).order("transaction_id",{ascending:false});
 },page);
 const transactionIds = result.rows.map(row => row.transaction_id);
 const timestamps = transactionIds.length ? await db.from("transactions").select("id,created_at")
  .eq("unit_id",unit).in("id",transactionIds) : {data: [], error: null};
 if(timestamps.error)throw new Error("Could not load transaction timestamps.");
 const recorded = new Map(timestamps.data.map(row=>[row.id,row.created_at]));
 return <FinanceListFrame header={header} controls={<FinanceListControls path={path} title="Sales" placeholder="Sale number" values={values} selects={selects}/>}><Panel>
 {result.rows.length?<Table headers={["Sale","Recorded","Total","Collected","Balance Due","Status"]}>{result.rows.map(s=><tr key={s.transaction_id}><td><Link href={`${path}/${s.transaction_id}`}>{s.code}</Link></td><td>{denverDateTime(recorded.get(s.transaction_id))}<br/><small>{denverCalendarDate(s.transaction_date)}</small></td><td>{money(s.amount)}</td><td>{money(s.collected)}</td><td>{money(s.balance_due)}</td><td><Badge>{s.status}</Badge></td></tr>)}</Table>:<Empty>No sales match these filters.</Empty>}
 </Panel><FinancePagination path={path} values={values} {...result}/></FinanceListFrame>;
}
