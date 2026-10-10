import {notFound} from "next/navigation";
import {DriverRoute} from "@/components/driver-route";
import {driverDates} from "@/lib/domain/driver-dates";
export const dynamic="force-dynamic";
export default async function RoutePage({params,searchParams}:{params:Promise<{leg:string}>;searchParams:Promise<{date?:string;route?:string}>}){
 const {leg}=await params; if(leg!=="pickup"&&leg!=="return") notFound();
 const query=await searchParams;const dates=driverDates(query.date);
 return <DriverRoute leg={leg} date={dates[leg]} routeId={query.route} />;
}
