import { context } from "@/lib/domain/context";
import {PickupRoute} from "@/components/pickup-route";
import {notFound} from "next/navigation";
import {ReturnRoute} from "@/components/return-route";
import {driverDates} from "@/lib/domain/driver-dates";
export const dynamic="force-dynamic";
export default async function RoutePage({params,searchParams}:{params:Promise<{leg:string}>;searchParams:Promise<{date?:string;route?:string}>}){
 const {leg}=await params; if(leg!=="pickup"&&leg!=="return") notFound();
 const query=await searchParams;const {db,unit}=await context();
 const {data:settings,error:settingsError}=await db.from("unit_settings").select("pickup_route_iso_weekdays,return_route_iso_weekdays").eq("unit_id",unit).single();
 if(settingsError)throw new Error("Could not load delivery route settings");
 const dates=driverDates(query.date,new Date(),settings.return_route_iso_weekdays,settings.pickup_route_iso_weekdays);
 if(leg==="pickup")return <PickupRoute date={dates.pickup} />;
 return <ReturnRoute date={dates.return} />;
}
