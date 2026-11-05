import {DriverRouteSelection,type DriverRouteOption} from "@/components/driver-route-selection";
import { redirect } from "next/navigation";
import { context } from "@/lib/domain/context";
import { driverDates } from "@/lib/domain/driver-dates";
export const dynamic = "force-dynamic";
export default async function PickReturnPage({searchParams}:{searchParams:Promise<{date?:string;mode?:string;route?:string}>}) {
 const query=await searchParams;
 const {db,unit}=await context();
 const {data:settings,error:settingsError}=await db.from("unit_settings").select("pickup_route_iso_weekdays,return_route_iso_weekdays").eq("unit_id",unit).single();
 if(settingsError)throw new Error("Could not load delivery route settings");
 const dates=driverDates(query.date,new Date(),settings.return_route_iso_weekdays,settings.pickup_route_iso_weekdays);
 if(query.mode==="pickup"||query.mode==="return") redirect(`/pick-return/${query.mode}?date=${query.mode==="pickup"?dates.pickup:dates.return}${query.route?`&route=${encodeURIComponent(query.route)}`:""}`);
 const {data:routes,error}=await db.from("pick_return_routes").select("id,leg,route_date").eq("unit_id",unit).in("route_date",[dates.pickup,dates.return]);
 if(error) throw new Error("Could not load daily routes");
 const ids=(routes??[]).map(r=>r.id);
 const result=ids.length?await db.from("pick_return_stops").select("route_id,job_id,status").eq("unit_id",unit).in("route_id",ids):{data:[],error:null};
 if(result.error) throw new Error("Could not load route progress");
 const pickupJobs=(result.data??[]).map(s=>s.job_id);
 const pickups=pickupJobs.length?await db.from("pick_return_orders").select("job_id").eq("unit_id",unit).in("job_id",pickupJobs).eq("fee_status","Confirmed").in("service_method",["Pickup Only","Pickup & Delivery"]):{data:[],error:null};
 if(pickups.error)throw new Error("Could not load confirmed Pickups");
 const confirmedPickups=new Set((pickups.data??[]).map(p=>p.job_id));
 const options:DriverRouteOption[]=(["pickup","return"] as const).map(leg=>{
  const date=dates[leg];const routeIds=new Set((routes??[]).filter(r=>r.leg===(leg==="pickup"?"Pickup":"Return")&&r.route_date===date).map(r=>r.id));
  const stops=(result.data??[]).filter(s=>routeIds.has(s.route_id)&&s.status!=="Cancelled"&&(leg!=="pickup"||confirmedPickups.has(s.job_id)));
  return {leg,date,total:stops.length,completed:stops.filter(s=>s.status==="Completed").length};
 });
 return <DriverRouteSelection selected={dates.selected} routes={options}/>;
}
