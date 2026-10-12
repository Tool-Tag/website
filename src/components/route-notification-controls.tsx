"use client";
import {useAccess} from "./permission-provider";
import {canAny} from "@/lib/auth/permissions";
import {RouteItemVerification} from "@/components/route-item-verification";
import {useEffect,useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {departDriverRoute,updateRouteLocation} from "@/app/route-notification-actions";
import {rememberDriverLocation} from "@/lib/domain/driver-location";
export function RouteNotificationControls({route,departed,closed,leg}:{route:string;departed?:string|null;closed:boolean;leg:"Pickup"|"Return"}){
 const access=useAccess();
 const [pending,start]=useTransition();const [error,setError]=useState("");const router=useRouter();const [tracking,setTracking]=useState(false);const [etaError,setEtaError]=useState("");const [verified,setVerified]=useState(false);
 useEffect(()=>{if(!tracking||closed)return;let last=0;let busy=false;let active=true;
 const watch=navigator.geolocation.watchPosition(position=>{const point={latitude:position.coords.latitude,longitude:position.coords.longitude};rememberDriverLocation(point);if(busy||Date.now()-last<45000)return;busy=true;last=Date.now();void updateRouteLocation(route,point).then(result=>{if(!active)return;setEtaError(result.error??"");if(!result.error)router.refresh();}).catch(()=>{if(active)setEtaError("ETA aprox. update failed. The next location update will retry.");}).finally(()=>{busy=false;});},()=>{if(active)setEtaError("Location unavailable. Enable location access to update ETA aprox.");},{enableHighAccuracy:true,maximumAge:10000,timeout:15000});return()=>{active=false;navigator.geolocation.clearWatch(watch);};},[tracking,closed,route,router]);
 if(!canAny(access,["driver.routes","pr.routes.live"]))return null;
 return <div className="pickup-controls">{leg==="Return"&&!departed&&!closed&&<RouteItemVerification route={route} kind="Loaded" onComplete={()=>setVerified(true)} />}{departed?<p className="notice success">{leg==="Pickup"?"Left the shop · customers notified":"Left the shop with items · customers notified"}</p>:<button disabled={pending||closed||(leg==="Return"&&!verified)} onClick={()=>start(async()=>{setError("");const result=await departDriverRoute(route);if(result.error)setError(result.error);else {if(navigator.geolocation)setTracking(true);router.refresh();}})}>{pending?"Notifying customers…":leg==="Return"?"Iniciar Ruta":"Leaving the shop · notify route"}</button>}{!closed&&<button className="secondary" onClick={()=>{if(!navigator.geolocation){setEtaError("Location is not supported on this device.");return;}setTracking(value=>!value);}}>{tracking?"Stop live ETA updates":"Enable live ETA aprox."}</button>}<p className="muted">ETA aprox. uses straight-line distance at 30 km/h plus 15 minutes per remaining stop. Keep this route open for location updates.</p>{etaError&&<p role="status">{etaError}</p>}{error&&<p className="notice error" role="alert">{error}</p>}</div>;
}
