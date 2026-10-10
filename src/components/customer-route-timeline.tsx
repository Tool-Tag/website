import {routeProgress,spanishStopStatus,type CustomerRoute,type CustomerRouteStop} from "@/lib/domain/customer-route-tracking";
import {TOOLTAG_TIMEZONE} from "@/lib/domain/time";
function local(value:string|null){return value?new Date(value).toLocaleString("es-MX",{timeZone:TOOLTAG_TIMEZONE,month:"short",day:"numeric",hour:"numeric",minute:"2-digit",timeZoneName:"short"}):"—";}
export function CustomerRouteTimeline({routes}:{routes:CustomerRoute[]}){
 return <div className="customer-routes">{routes.map(route=>{
  const progress=routeProgress(route.stops);
  const stop=(s:CustomerRouteStop)=><li key={s.position} className={`customer-route-stop${s.is_customer?" own-stop":""}`}><span className="status-dot" aria-hidden="true">{progress.done.includes(s)?"✓":progress.current.includes(s)?"●":"○"}</span><div><strong>Parada {s.position}{s.is_customer?" · Tu parada":""}</strong><span>{spanishStopStatus[s.status]??"Pendiente"}</span></div></li>;
  return <section className="panel customer-route" key={`${route.leg}:${route.date}`} aria-label={`Ruta de ${route.leg==="Pickup"?"recolección":"entrega"}`}>
   <p className="status-kicker">Seguimiento de ruta</p><h2>{route.leg==="Pickup"?"Recolección":"Entrega"}</h2>
   <p>{new Date(route.date+"T12:00:00Z").toLocaleDateString("es-MX",{timeZone:TOOLTAG_TIMEZONE,weekday:"long",month:"long",day:"numeric"})}</p>
   <p className="muted">Ventana: {local(route.window_start)} – {local(route.window_end)}</p>
   <div className="route-eta-summary" aria-live="polite"><strong>ETA aprox. · {route.paused?"Ruta en pausa":route.own_status==="Arrived"?"El conductor está en tu parada":route.estimated_eta?local(route.estimated_eta):["Completed","Failed","Cancelled"].includes(route.own_status)?"Parada finalizada":"Esperando ubicación actualizada"}</strong><p>Estimación, nunca una hora fija. Puede cambiar por tráfico, espera o cambios en la ruta.</p>
    {route.estimated_eta&&<><p>{route.remaining_to_customer} parada(s) hasta la tuya. Cálculo: tiempo de viaje estimado + 15 min por parada restante.</p><small>Ubicación actualizada: {local(route.estimate_updated_at)}</small></>}
    {!route.estimated_eta&&!["Completed","Failed","Cancelled","Arrived"].includes(route.own_status)&&<p>Mostraremos la estimación cuando haya datos recientes de ubicación. El horario programado no se usa como ETA.</p>}
   </div>
   <div className="customer-route-groups"><details open={progress.done.length===route.stops.length}><summary>✓ Finalizadas ({progress.done.length})</summary><ol>{progress.done.map(stop)}</ol></details><section aria-label="Parada actual"><h3>● Actual</h3>{progress.current.length?<ol>{progress.current.map(stop)}</ol>:<p className="muted">{route.closed?"Ruta cerrada":progress.percentage===100?"Recorrido finalizado; pendiente de confirmación de ToolTag":"Aún no hay una parada en curso"}</p>}</section><details open={progress.current.length===0&&progress.percentage!==100}><summary>○ Próximas ({progress.upcoming.length})</summary><ol>{progress.upcoming.map(stop)}</ol></details></div>
   <label>Avance de la ruta: {progress.percentage}%<progress max={100} value={progress.percentage} aria-label="Avance de la ruta" /></label><p className="muted">{progress.done.length}/{route.total} paradas resueltas · Última actualización: {local(route.updated_at)}</p>
  </section>;
 })}</div>;
}
