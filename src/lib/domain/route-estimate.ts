export type Point = {latitude:number;longitude:number};
export function validPoint(point:Point):boolean{
 return Number.isFinite(point.latitude)&&Number.isFinite(point.longitude)&&Math.abs(point.latitude)<=90&&Math.abs(point.longitude)<=180;
}
export function straightLineKm(a:Point,b:Point){
 if(!validPoint(a)||!validPoint(b))throw new Error("Invalid coordinates");
 const rad=(n:number)=>n*Math.PI/180;
 const h=Math.sin(rad(b.latitude-a.latitude)/2)**2+Math.cos(rad(a.latitude))*Math.cos(rad(b.latitude))*Math.sin(rad(b.longitude-a.longitude)/2)**2;
 return 6371*2*Math.asin(Math.sqrt(Math.min(1,h)));
}
// Replace this provider with a road-travel implementation without changing notification logic.
export interface RouteTravelProvider {minutes(origin:Point,orderedStops:Point[]):Promise<number[]>}
export const simpleRouteTravel:RouteTravelProvider={async minutes(origin,stops){
 let travel=0;let previous=origin;
 return stops.map((stop,index)=>{travel+=straightLineKm(previous,stop)/30*60;previous=stop;return Math.ceil(travel+15*(index+1));});
}};
