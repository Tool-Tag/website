import type {ReactNode} from "react";
import Link from "next/link";
import {context,rows} from "@/lib/domain/context";
import {financeFilters,financePage,type FinanceSearch,type FinanceSelect} from "@/lib/domain/finance-list";
import {FinanceListFrame} from "@/components/finance-list-frame";
import {FinanceListControls,FinancePagination} from "@/components/finance-list-controls";
import {EquipmentRegistrationModal} from "@/components/equipment-registration-modal";
import {Panel,Table,Empty} from "@/components/ui";
import {FinanceMileageList} from "./finance-mileage-list";
import {money} from "@/lib/domain/money";
const selects:FinanceSelect[]=[{name:"paid_by",label:"Paid by",options:["Business","Owner"]},{name:"kind",label:"Category type",options:["Equipment","Operating"]},{name:"receipt",label:"Receipt",options:["Receipt Attached","Receipt Missing — Required","Receipt Not Required (<$75)"]}];
export async function FinanceExpensesList({header,search={},created}:{header:ReactNode;search?:FinanceSearch;created?:string}){
 const {db,unit,access}=await context(),{values,page}=financeFilters(search,selects),path="/app/finance/expenses";
 const listHeader=<>{header}<nav className="main-tab-list" aria-label="Expense sections"><Link className={`main-tab ${search.view!=="mileage"?"active":""}`} href={path}>Expenses</Link><Link className={`main-tab ${search.view==="mileage"?"active":""}`} href={`${path}?view=mileage`}>Trip/Mileage</Link></nav></>;
 if(search.view==="mileage")return <FinanceMileageList header={listHeader} search={search}/>;
 const result=await financePage(head=>{
  let q=db.from("expense_details").select("*",{count:head?"exact":undefined,head}).eq("unit_id",unit);
  if(values.q)q=q.or(`description.ilike.*${values.q}*,vendor.ilike.*${values.q}*`);
  if(values.paid_by)q=q.eq("paid_by",values.paid_by);if(values.kind)q=q.eq("is_equipment",values.kind==="Equipment");if(values.receipt)q=q.eq("receipt_status",values.receipt);
  if(values.from)q=q.gte("transaction_date",values.from);if(values.to)q=q.lte("transaction_date",values.to);
  return q.order("transaction_date",{ascending:false}).order("transaction_id",{ascending:false});
 },page);
 const validCreated=typeof created==="string"&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(created);
 const saved=validCreated?(await rows("expense_details",{field:"transaction_id",value:created}))[0]:undefined;
 const categories=saved?.is_equipment&&!saved.linked_asset_id&&access.owner?(await rows("categories")).filter(c=>c.kind==="asset"&&c.active).map(c=>({value:c.id,label:c.name})):[];
 return <FinanceListFrame header={listHeader} controls={<FinanceListControls path={path} title="Expenses" placeholder="Description or vendor" values={values} selects={selects}/>}>
 {saved?.is_equipment&&!saved.linked_asset_id&&access.owner&&<EquipmentRegistrationModal key={saved.transaction_id} categories={categories} expense={{id:saved.transaction_id,description:saved.description,amount:String(saved.amount),vendor:saved.vendor??"",date:saved.transaction_date}}/>}
 <Panel>{result.rows.length?<Table headers={["Expense","Amount","Paid By","Reimbursement Due","Receipt"]}>{result.rows.map(e=><tr key={e.transaction_id}><td><Link href={`/app/finance/transactions/${e.transaction_id}`}>{e.description}</Link><br/><small>{e.vendor}</small></td><td>{money(e.amount)}</td><td>{e.paid_by}</td><td>{e.paid_by==="Owner"?money(e.reimbursement_due):"—"}</td><td>{e.receipt_status}</td></tr>)}</Table>:<Empty>No expenses match these filters.</Empty>}</Panel><FinancePagination path={path} values={values} {...result}/>

 </FinanceListFrame>;
}
