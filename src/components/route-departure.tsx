import { context } from "@/lib/domain/context";
export async function RouteDeparture() {
 const {db,unit}=await context();
 const {data}=await db.from("unit_settings").select("route_departure_address").eq("unit_id",unit).maybeSingle();
 if(!data?.route_departure_address)return null;
 return <aside className="notice"><strong>Route departure point</strong><p>{data.route_departure_address}</p><small>Departure reference only. Approximate ETA uses your current location.</small></aside>;
}
