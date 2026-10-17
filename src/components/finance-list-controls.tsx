import {TRANSACTION_PAGE_SIZE} from "@/lib/domain/transaction-filters";
import Link from "next/link";
import {financePageUrl,type FinanceSelect} from "@/lib/domain/finance-list";
export function FinanceListControls({path,title,placeholder,values,selects}:{path:string;title:string;placeholder:string;values:Record<string,string>;selects:FinanceSelect[]}){
 return <section className="transaction-filter-panel" aria-label={`${title} search and filters`}><h2>{title}</h2>
 <form method="get" action={path} className="transaction-filter-form" key={JSON.stringify(values)}>
 {values.view&&<input type="hidden" name="view" value={values.view}/>}
 <label>Search<input type="search" name="q" defaultValue={values.q} maxLength={100} placeholder={placeholder}/></label>
 {selects.map(select=><label key={select.name}>{select.label}<select name={select.name} defaultValue={values[select.name]??""}><option value="">All</option>{select.options.map(option=><option key={option}>{option}</option>)}</select></label>)}
 <label>From<input type="date" name="from" defaultValue={values.from}/></label><label>To<input type="date" name="to" defaultValue={values.to}/></label>
 <div className="actions"><button type="submit">Apply filters</button><Link className="button secondary" href={path}>Clear</Link></div></form>
 {values.from&&values.to&&values.from>values.to&&<p role="alert">The start date must be on or before the end date.</p>}
 </section>;
}
export function FinancePagination({path,values,total,page,pages}:{path:string;values:Record<string,string>;total:number;page:number;pages:number}){
 return <><p role="status">{total} record{total===1?"":"s"} · {total?`${(page-1)*TRANSACTION_PAGE_SIZE+1}–${Math.min(page*TRANSACTION_PAGE_SIZE,total)}`:"0"} shown</p>
 <nav className="actions pagination" aria-label="Finance pages">{page>1?<Link className="button secondary" href={financePageUrl(path,values,page-1)}>Previous</Link>:<button type="button" disabled>Previous</button>}<span>Page {page} of {pages}</span>{page<pages?<Link className="button secondary" href={financePageUrl(path,values,page+1)}>Next</Link>:<button type="button" disabled>Next</button>}</nav></>;
}
