import {canAny,type Access} from "@/lib/auth/permissions";
/** Stable keys for paging the existing shop tables; several do not have an id column. */
export const SHOP_BOARD_ORDER_KEYS = {
 lost_replacement_deliveries:"id",
 pick_return_orders:"job_id",
 jobs:"id",
 job_items:"id",
 pick_return_routes:"id",
 pick_return_stops:"id",
 documents:"id",
 commercial_flows:"id",
 customers:"id",
 quote_logistics:"quote_id",
 failed_delivery_verifications:"stop_id",
} as const;
export type ShopBoardTable=keyof typeof SHOP_BOARD_ORDER_KEYS;

export function shopBoardLeg(access:Access,requested?:string) {
 const pickup=canAny(access,["pr.routes.plan","pr.routes.live","pr.receiving","pr.reschedule"]);
 const delivery=canAny(access,["pr.routes.plan","pr.routes.live","pr.returns","pr.reschedule"]);
 return {pickup,delivery,leg:((requested==="Delivery"&&delivery)||(!pickup&&delivery)?"Return":"Pickup") as "Return"|"Pickup"};
}
