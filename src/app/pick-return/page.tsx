import Link from "next/link";
import { redirect } from "next/navigation";
import { context } from "@/lib/domain/context";
import { driverDates, routeDateLabel } from "@/lib/domain/driver-dates";
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
 return <section className="driver-landing">
  <p className="eyebrow">TOOLTAG / ON THE ROAD</p><h1>Pick up & Return</h1><p className="muted">Choose your route. One stop at a time.</p>
  <form className="driver-date" action="/pick-return"><label htmlFor="route-day">View another day<input id="route-day" type="date" name="date" defaultValue={dates.selected} required /></label><button className="secondary">View routes</button></form>
  <div className="driver-cards">{(["pickup","return"] as const).map(leg=>{
   const date=dates[leg];const routeIds=new Set((routes??[]).filter(r=>r.leg===(leg==="pickup"?"Pickup":"Return")&&r.route_date===date).map(r=>r.id));
   const stops=(result.data??[]).filter(s=>routeIds.has(s.route_id)&&s.status!=="Cancelled"&&(leg!=="pickup"||confirmedPickups.has(s.job_id))); const done=stops.filter(s=>s.status==="Completed").length;
   return <Link className={`driver-card driver-${leg}`} href={`/pick-return/${leg}?date=${date}`} key={leg}>
    <div className="driver-card-heading"><span className="driver-icon" aria-hidden="true">{leg==="pickup"?"↗":"↙"}</span><h2>{leg==="pickup"?"Pick up":"Return"}</h2><span aria-hidden="true">→</span></div>
    <p className="driver-route-date">{routeDateLabel(date)}</p><p className="driver-window">Starts {leg==="pickup"?"8:00 AM":"2:00 PM"} <span>Denver time</span></p>
    <div className="driver-stats"><strong>{stops.length} stops</strong><span>{done}/{stops.length} completed</span></div>
    <progress value={done} max={stops.length||1} aria-label={`${leg} route progress`} />
    <span className="driver-open">Open {leg==="pickup"?"pickup":"Return"} route <span aria-hidden="true">→</span></span>
   </Link>;
  })}</div>
 </section>;
}
