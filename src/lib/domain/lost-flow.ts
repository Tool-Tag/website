export type LostStatus = "New" | "In Process" | "History";
export type LostChoice = "Replace Item" | "Refund money";
export type LostCase = {
 id:string;job:string;customer:string;phone:string;driver:string;driver_id:string|null;driver_email:string|null;
 route_date:string;explanation:string;reported_at:string;items:{id:string;article:string;sequence:number}[];
 status?:LostStatus;market_value?:number|null;customer_choice?:LostChoice|null;responded_at?:string|null;
 notified_at?:string|null;approved_at?:string|null;refund_id?:string|null;refund_status?:string|null;finalized_at?:string|null;resolution_notes?:string|null;
};
export function lostCanFinalize(row:Pick<LostCase,"approved_at"|"customer_choice"|"refund_status"|"status">) {
 return row.status==="In Process" && Boolean(row.approved_at) && (row.customer_choice==="Replace Item" || (row.customer_choice==="Refund money" && row.refund_status==="Completed"));
}
