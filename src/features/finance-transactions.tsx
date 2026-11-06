import {FinanceListFrame} from "@/components/finance-list-frame";
import type {ReactNode} from "react";
import Link from "next/link";
import {context} from "@/lib/domain/context";
import {Panel,Table,Empty,Badge} from "@/components/ui";
import {money} from "@/lib/domain/money";
import {transactionFilters,transactionPageUrl,TRANSACTION_TYPES,TRANSACTION_STATUSES,TRANSACTION_PAGE_SIZE,type TransactionSearch} from "@/lib/domain/transaction-filters";

export async function FinanceTransactions({search={},header}:{search?:TransactionSearch;header?:ReactNode}) {
  const {db,unit}=await context(),filters=transactionFilters(search);
  const accounts:{id:string;name:string}[]=[];
  for(let offset=0;;offset+=500){
    const {data,error}=await db.from("accounts").select("id,name").eq("unit_id",unit).order("id").range(offset,offset+499);
    if(error)throw new Error("Unable to load transaction accounts.");accounts.push(...(data??[]));if((data?.length??0)<500)break;
  }
  const invalidRange=Boolean(filters.from&&filters.to&&filters.from>filters.to);
  function query(page:number,head=false){
    let q=db.from("transactions").select("id,transaction_date,description,type,amount,status",{count:head?"exact":undefined,head}).eq("unit_id",unit);
    if(filters.q)q=q.or(["description","vendor","reference"].map(field=>`${field}.ilike.*${filters.q}*`).join(","));
    if(filters.type)q=q.eq("type",filters.type);
    if(filters.status)q=q.eq("status",filters.status);
    if(filters.account)q=q.eq("account_id",filters.account);
    if(filters.from)q=q.gte("transaction_date",filters.from);
    if(filters.to)q=q.lte("transaction_date",filters.to);
    if(head)return q;
    const offset=(page-1)*TRANSACTION_PAGE_SIZE;
    return q.order("transaction_date",{ascending:false}).order("created_at",{ascending:false}).order("id",{ascending:false}).range(offset,offset+TRANSACTION_PAGE_SIZE-1);
  }
  const countResult=await query(1,true);
  if(countResult.error)throw new Error("Unable to count filtered transactions.");
  const total=countResult.count??0,pages=Math.max(1,Math.ceil(total/TRANSACTION_PAGE_SIZE)),page=Math.min(filters.page,pages);
  const result=await query(page);
  if(result.error)throw new Error("Unable to load filtered transactions.");
  return <FinanceListFrame header={header} controls={<section className="transaction-filter-panel" aria-label="Transaction search and filters"><h2>Transactions</h2>
    <form method="get" action="/app/finance/transactions" className="transaction-filter-form" key={JSON.stringify(filters)}>
      <label className="wide">Search<input name="q" type="search" defaultValue={filters.q} maxLength={100} placeholder="Description, vendor or reference"/></label>
      <label>Type<select name="type" defaultValue={filters.type}><option value="">All types</option>{TRANSACTION_TYPES.map(type=><option key={type} value={type}>{type.replaceAll("_"," ")}</option>)}</select></label>
      <label>Status<select name="status" defaultValue={filters.status}><option value="">All statuses</option>{TRANSACTION_STATUSES.map(status=><option key={status}>{status}</option>)}</select></label>
      <label>Account<select name="account" defaultValue={filters.account}><option value="">All ToolTag accounts</option>{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
      <label>From<input type="date" name="from" defaultValue={filters.from}/></label>
      <label>To<input type="date" name="to" defaultValue={filters.to}/></label>
      <div className="actions wide"><button type="submit">Apply filters</button><Link className="button secondary" href="/app/finance/transactions">Clear</Link></div>
    </form>
    </section>}>
    <Panel>
    {invalidRange&&<p role="alert">The start date must be on or before the end date.</p>}

    {result.data?.length?<Table headers={["Date","Transaction","Type","Amount","Status"]}>{result.data.map(t=><tr key={t.id}><td>{t.transaction_date}</td><td><Link href={`/app/finance/transactions/${t.id}`}>{t.description}</Link></td><td>{t.type}</td><td>{money(t.amount)}</td><td><Badge>{t.status}</Badge></td></tr>)}</Table>:<Empty>No transactions match these filters.</Empty>}
    </Panel><nav className="actions pagination" aria-label="Transaction pages">
      {page>1?<Link className="button menu-link-gold" href={transactionPageUrl(filters,page-1)}>Previous</Link>:<button type="button" disabled>Previous</button>}
      <span>Page {page} of {pages}</span>
      {page<pages?<Link className="button menu-link-gold" href={transactionPageUrl(filters,page+1)}>Next</Link>:<button type="button" disabled>Next</button>}
    </nav>
  </FinanceListFrame>;
}
