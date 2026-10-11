import {routeProgress,type CustomerRoute,type CustomerRouteStop} from "@/lib/domain/customer-route-tracking";
import {TOOLTAG_TIMEZONE} from "@/lib/domain/time";
function local(value:string|null){return value?new Date(value).toLocaleString("en-US",{timeZone:TOOLTAG_TIMEZONE,month:"short",day:"numeric",hour:"numeric",minute:"2-digit",timeZoneName:"short"}):"—";}
export function CustomerRouteTimeline({routes}:{routes:CustomerRoute[]}){
 return <div className="customer-routes">{routes.map(route=>{
  const progress=routeProgress(route.stops);
  const stop=(s:CustomerRouteStop)=><li key={s.position} className={`customer-route-stop${s.is_customer?" own-stop":""}`}><span className="status-dot" aria-hidden="true">{progress.done.includes(s)?"✓":progress.current.includes(s)?"●":"○"}</span><div><strong>Stop {s.position}{s.is_customer?" · Your stop":""}</strong><span>{s.status==="Completed"?(route.leg==="Pickup"?"Picked Up":"Delivered"):s.status}</span></div></li>;
  return <section className="panel customer-route" key={`${route.leg}:${route.date}`} aria-label={`Route · ${route.leg==="Pickup"?"Pickup":"Delivery"}`}>
   <p className="status-kicker">Route tracking</p><h2>{route.leg==="Pickup"?"Pickup":"Delivery"}</h2>
   <p>{new Date(route.date+"T12:00:00Z").toLocaleDateString("en-US",{timeZone:TOOLTAG_TIMEZONE,weekday:"long",month:"long",day:"numeric"})}</p>
   <p className="muted">Window: {local(route.window_start)} – {local(route.window_end)}</p>
   <div className="route-eta-summary" aria-live="polite"><strong>Approx. ETA · {route.paused?"Route paused":route.own_status==="Arrived"?"Your driver has arrived":route.estimated_eta?local(route.estimated_eta):["Completed","Failed","Cancelled"].includes(route.own_status)?"Stop completed":"Waiting for a location update"}</strong><p>Estimated, never a fixed time. Traffic, waiting and route changes may affect it.</p>
    {route.estimated_eta&&<><p>{route.remaining_to_customer} stop(s) until yours. Calculation: estimated travel time + 15 minutes per remaining stop.</p><small>Location updated: {local(route.estimate_updated_at)}</small></>}
    {!route.estimated_eta&&!["Completed","Failed","Cancelled","Arrived"].includes(route.own_status)&&<p>We will show an estimate when recent location data is available. The scheduled time is not a live ETA.</p>}
   </div>
   <div className="customer-route-groups"><section aria-label="Upcoming stops"><h3>○ Upcoming</h3><ol>{progress.upcoming.slice(0,1).map(stop)}</ol>{progress.upcoming.length>1&&<details><summary>More upcoming stops ({progress.upcoming.length-1})</summary><ol>{progress.upcoming.slice(1).map(stop)}</ol></details>}</section><section className="route-current" aria-label="Current stop"><h3>● Current</h3>{progress.current.length?<ol>{progress.current.map(stop)}</ol>:<p className="muted">{route.closed?"Route closed":progress.percentage===100?"Route finished; awaiting ToolTag confirmation":"No stop is in progress yet"}</p>}</section><details><summary>✓ Completed ({progress.done.length})</summary><ol>{progress.done.map(stop)}</ol></details></div>
   <label className="tracking-progress">Route progress: {progress.percentage}%<progress max={100} value={progress.percentage} aria-label="Route progress" /></label><p className="muted">{progress.done.length}/{route.total} stops resolved · Last updated: {local(route.updated_at)}</p>
  </section>;
 })}</div>;
}
