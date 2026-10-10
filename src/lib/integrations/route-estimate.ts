import {simpleRouteTravel,validPoint,type Point,type RouteTravelProvider} from "@/lib/domain/route-estimate";
import type {SupabaseClient} from "@supabase/supabase-js";
export async function geocodeAddress(address:string,request:typeof fetch=fetch):Promise<Point|null>{
 if(!address?.trim())return null;
 try{
 const url=new URL("https://geocoding.geo.census.gov/geocoder/locations/onelineaddress");url.search=new URLSearchParams({address,benchmark:"Public_AR_Current",format:"json"}).toString();
 const response=await request(url,{signal:AbortSignal.timeout(4000),cache:"no-store"});if(!response.ok)return null;
 const data=await response.json();const matches=data?.result?.addressMatches;if(!Array.isArray(matches)||matches.length!==1)return null;
 const coordinates=matches[0]?.coordinates;const point={latitude:coordinates?.y,longitude:coordinates?.x};return validPoint(point)?point:null;
 }catch{return null;}
}
export async function refreshRouteEstimates(db:SupabaseClient,route:string,origin?:Point|null,provider:RouteTravelProvider=simpleRouteTravel){
 const snapshot=await db.rpc("driver_route_estimate_context",{p_route:route});if(snapshot.error)throw new Error(snapshot.error.message);
 if(snapshot.data.closed)return;
 const stops=snapshot.data.stops as {id:string;address:string;latitude:number|null;longitude:number|null}[];
 // Sequential batches bound geocoder load and keep a single request within Vercel limits.
 const points:(Point|null)[]=[];
 for(let i=0;i<stops.length;i+=5){points.push(...await Promise.all(stops.slice(i,i+5).map(s=>s.latitude!==null&&s.longitude!==null?Promise.resolve({latitude:s.latitude,longitude:s.longitude}):geocodeAddress(s.address))));}
 const validUntil=points.findIndex(p=>!p);const known=points.slice(0,validUntil<0?points.length:validUntil) as Point[];
 const minutes=origin&&validPoint(origin)?await provider.minutes(origin,known):[];
 const estimates=stops.map((stop,i)=>({id:stop.id,minutes:minutes[i]??null,latitude:points[i]?.latitude,longitude:points[i]?.longitude}));
 const saved=await db.rpc("update_driver_route_estimates",{p_route:route,p_estimates:estimates});if(saved.error)throw new Error(saved.error.message);
}
export async function refreshStopRouteEstimates(db:SupabaseClient,stop:string,origin?:Point|null){
 const result=await db.from("pick_return_stops").select("route_id").eq("id",stop).single();if(result.error)throw new Error(result.error.message);
 await refreshRouteEstimates(db,result.data.route_id,origin);
}
