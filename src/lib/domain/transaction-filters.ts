export const TRANSACTION_PAGE_SIZE = 20;
export const TRANSACTION_TYPES = ["SALE","COLLECTION","EXPENSE","OWNER_INJECTION","OWNER_DRAW","INTER_UNIT_TRANSFER","REFUND"];
export const TRANSACTION_STATUSES = ["Active","Voided","Archived"];
export type TransactionSearch = {q?:string;type?:string;status?:string;account?:string;from?:string;to?:string;page?:string};
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
function date(value = "") {
  if(typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return "";
  const parsed = new Date(`${value}T12:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0,10) === value ? value : "";
}
export function transactionFilters(input:TransactionSearch) {
  // Only literal search text enters PostgREST's OR expression, never its grammar
  // characters or SQL wildcard syntax. Search matches all three text columns.
  const q=(typeof input.q === "string" ? input.q : "").replace(/[^\p{L}\p{N}\s@.\/#-]/gu," ").replace(/\s+/g," ").trim().slice(0,100);
  const page=Number(input.page);
  return {q,type:TRANSACTION_TYPES.includes(input.type??"")?input.type!:"",status:TRANSACTION_STATUSES.includes(input.status??"")?input.status!:"",account:typeof input.account === "string" && uuid.test(input.account)?input.account!:"",from:date(input.from),to:date(input.to),page:Number.isSafeInteger(page)&&page>0?Math.min(page,1000000):1};
}
export function transactionPageUrl(filters:ReturnType<typeof transactionFilters>,page:number) {
  const params=new URLSearchParams();
  for(const key of ["q","type","status","account","from","to"] as const)if(filters[key])params.set(key,filters[key]);
  params.set("page",String(page));return `/app/finance/transactions?${params}`;
}
