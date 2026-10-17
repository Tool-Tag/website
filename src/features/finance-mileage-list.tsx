import type {ReactNode} from "react";
import {context} from "@/lib/domain/context";
import {financeFilters,financePage,type FinanceSearch} from "@/lib/domain/finance-list";
import {FinanceListFrame} from "@/components/finance-list-frame";
import {FinanceListControls,FinancePagination} from "@/components/finance-list-controls";
import {Empty,Panel,Table} from "@/components/ui";
import {ActionModal} from "@/components/action-modal";
import {MileageForm} from "@/components/mileage-form";
export async function FinanceMileageList({header,search}:{header:ReactNode;search:FinanceSearch}) {
 const {db,unit,access}=await context(),{values,page}=financeFilters(search,[]),path="/app/finance/expenses";values.view="mileage";
 const result=await financePage(head=>{
 let q=db.from("mileage").select("*",{head,count:head?"exact":undefined}).eq("unit_id",unit);
 if(values.q)q=q.or(["purpose","origin","destination","notes"].map(key=>`${key}.ilike.*${values.q}*`).join(","));
 if(values.from)q=q.gte("date",values.from);if(values.to)q=q.lte("date",values.to);
 return q.order("date",{ascending:false}).order("id",{ascending:false});},page);
 return <FinanceListFrame header={header} controls={<FinanceListControls path={path} title="Trip/Mileage" values={values} selects={[]} placeholder="Purpose, origin or destination"/>}>
 {access.owner&&<div className="actions"><ActionModal label="Record trip / mileage" title="Trip/Mileage"><MileageForm/></ActionModal></div>}
 <Panel>{result.rows.length?<Table headers={["Date","Purpose","Origin","Destination","Miles","Notes"]}>{result.rows.map(row=><tr key={row.id}><td>{row.date}</td><td>{row.purpose}</td><td>{row.origin}</td><td>{row.destination}</td><td>{row.miles}</td><td>{row.notes||"—"}</td></tr>)}</Table>:<Empty>No trips match these filters.</Empty>}</Panel>
 <FinancePagination path={path} values={values} {...result}/></FinanceListFrame>;
}
