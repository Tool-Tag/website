import {transactionFilters,TRANSACTION_PAGE_SIZE,type TransactionSearch} from "./transaction-filters";
import {TOOLTAG_TIMEZONE} from "./time";
export type FinanceSearch=TransactionSearch&{paid_by?:string;receipt?:string;kind?:string;method?:string;reason?:string;state?:string};
export type FinanceSelect={name:keyof FinanceSearch;label:string;options:string[]};
export function financeFilters(input:FinanceSearch,selects:FinanceSelect[]){
 const basic=transactionFilters(input),values:Record<string,string>={q:basic.q,from:basic.from,to:basic.to};
 for(const select of selects){const value=input[select.name];values[select.name]=typeof value==="string"&&select.options.includes(value)?value:"";}
 return {values,page:basic.page};
}
export function financePageUrl(path:string,values:Record<string,string>,page:number){const params=new URLSearchParams();for(const [key,value] of Object.entries(values))if(value)params.set(key,value);params.set("page",String(page));return `${path}?${params}`;}
export function denverDateBoundary(date:string,next=false){
 const target=new Date(`${date}T00:00:00Z`);if(next)target.setUTCDate(target.getUTCDate()+1);
 const expected=target.getTime();let guess=expected+6*3600000;
 const formatter=new Intl.DateTimeFormat("en-US",{timeZone:TOOLTAG_TIMEZONE,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit",hourCycle:"h23"});
 for(let i=0;i<3;i++){const parts=formatter.formatToParts(new Date(guess));const n=(type:string)=>Number(parts.find(p=>p.type===type)!.value);const actual=Date.UTC(n("year"),n("month")-1,n("day"),n("hour"),n("minute"),n("second"));guess+=expected-actual;}
 return new Date(guess).toISOString();
}
type PageResponse<T>={data:T[]|null;count:number|null;error:{message:string}|null};
type PageQuery<T>=PromiseLike<PageResponse<T>>&{range:(from:number,to:number)=>PageQuery<T>};
export async function financePage<T>(query:(head:boolean)=>PageQuery<T>,requested:number){
 const count=await query(true);if(count.error)throw new Error("Unable to count filtered finance records.");
 const total=count.count??0,pages=Math.max(1,Math.ceil(total/TRANSACTION_PAGE_SIZE)),page=Math.min(requested,pages),offset=(page-1)*TRANSACTION_PAGE_SIZE;
 const result=await query(false).range(offset,offset+TRANSACTION_PAGE_SIZE-1);if(result.error)throw new Error("Unable to load filtered finance records.");
 return {rows:result.data??[],total,pages,page};
}
