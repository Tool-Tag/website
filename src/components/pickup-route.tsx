import {RouteExceptionControls} from "@/components/route-exception-controls";
import {RouteNotificationControls} from "@/components/route-notification-controls";
import Link from "next/link";
import {context} from "@/lib/domain/context";
import {denverTime} from "@/lib/domain/time";
import {routeDateLabel} from "@/lib/domain/driver-dates";
import {PickupStopControls} from "@/components/pickup-stop-controls";
import {EvidenceUpload} from "@/components/evidence-upload";
import {EvidenceGallery} from "@/components/evidence-gallery";
import {Form} from "@/components/form";
import {StatusRefresh} from "@/components/status-refresh";
export async function PickupRoute({date}:{date:string}){
 const {db,unit}=await context();
 const {data:routes,error}=await db.from("pick_return_routes").select("*").eq("unit_id",unit).eq("leg","Pickup").eq("route_date",date);
 if(error)throw new Error("Could not load Pickup routes");
 const ids=(routes??[]).map(r=>r.id);
 const {data:stops,error:stopError}=ids.length?await db.from("pick_return_stops").select("*").eq("unit_id",unit).in("route_id",ids).order("sequence"):{data:[],error:null};
 if(stopError)throw new Error("Could not load Pickup stops");
 const {data:incidents,error:incidentError}=ids.length?await db.from("route_incidents").select("id,route_id,status,deadline").eq("unit_id",unit).in("route_id",ids):{data:[],error:null};
 if(incidentError)throw new Error("Could not load route exceptions");
 const jobIds=(stops??[]).map(s=>s.job_id);
 const results=jobIds.length?await Promise.all([
 db.from("pick_return_orders").select("*").eq("unit_id",unit).in("job_id",jobIds).in("service_method",["Pickup Only","Pickup & Delivery"]).eq("fee_status","Confirmed"),
 db.from("jobs").select("*").eq("unit_id",unit).in("id",jobIds),
 db.from("job_items").select("job_id,article,sequence").eq("unit_id",unit).in("job_id",jobIds).order("sequence"),
 db.from("documents").select("*").eq("unit_id",unit).in("job_id",jobIds).eq("type","Receiving Evidence").eq("status","Available"),
 db.from("commercial_flows").select("id,customer_id").eq("unit_id",unit),
 db.from("customers").select("id,name,phone").eq("unit_id",unit)
 ]):[];
 if(results.some(r=>r.error))throw new Error("Could not load Pickup details");
 const [orders,jobs,items,documents,flows,customers]=results.map(r=>r.data??[]);
 const allowed=new Set((orders??[]).filter(o=>o.pickup_window_start&&new Date(o.pickup_window_start).toLocaleDateString("en-CA",{timeZone:"America/Denver"})===date).map(o=>o.job_id));
 const visible=(stops??[]).filter(s=>s.status!=="Cancelled"&&allowed.has(s.job_id));
 return <section className="pickup-route driver-landing"><StatusRefresh />
 <Link className="button secondary" href="/pick-return">← All routes</Link><p className="eyebrow">SATURDAY / PICK UP</p><h1>{routeDateLabel(date)}</h1><p className="driver-window">8:00 AM–12:00 PM · Denver time</p><p>{visible.filter(s=>s.status==="Completed").length}/{visible.length} picked up</p>
 {(routes??[]).map(route=><RouteNotificationControls key={route.id} route={route.id} departed={route.departed_at} closed={Boolean(route.confirmed_at)||["Completed","Cancelled"].includes(route.status)} />)}
 {(routes??[]).map(route=><RouteExceptionControls key={route.id} route={route.id} leg="Pickup" incident={(incidents??[]).find(i=>i.route_id===route.id)} closed={Boolean(route.confirmed_at)||["Completed","Cancelled"].includes(route.status)} />)}
 {!visible.length&&<div className="panel"><h2>No confirmed pickups</h2><p>Only scheduled Pickup services with confirmed payment appear here.</p></div>}
 {visible.map((stop,index)=>{
 const job=(jobs??[]).find(j=>j.id===stop.job_id);if(!job)return null;
 const flow=(flows??[]).find(f=>f.id===job.flow_id);const customer=(customers??[]).find(c=>c.id===flow?.customer_id);
 const evidence=(documents??[]).filter(d=>d.pick_return_stop_id===stop.id);
 const pieces=(items??[]).filter(i=>i.job_id===job.id);const summary=new Map<string,number>();pieces.forEach(i=>summary.set(i.article,(summary.get(i.article)??0)+1));
 const paused=(incidents??[]).some(i=>i.route_id===stop.route_id&&i.status==="Open");
 const blocked=paused||job.status==="Cancelled"||/Cancellation Requested|Production Hold/.test(job.work_stage??"");
 return <article id={`pickup-stop-${stop.id}`} className="driver-card pickup-stop" key={stop.id}><div className="driver-card-heading"><span className="driver-icon">{index+1}</span><div><h2>{customer?.name??"Customer"}</h2><p>{job.code} · {stop.status==="Completed"?"Picked Up":stop.status}</p></div></div>
 {customer?.phone&&<a className="button secondary" href={`tel:${customer.phone.replace(/[^+0-9]/g,"")}`}>{customer.phone}</a>}
 <p className="pickup-address">{stop.address||"Pickup address unavailable"}</p><p>Window: 8:00 AM–12:00 PM</p>{stop.approximate_eta&&<p><strong>ETA aprox.: {denverTime(stop.approximate_eta)}</strong></p>}{stop.eta&&<p><strong>ETA: {denverTime(stop.eta)}</strong></p>}
 <h3>{pieces.length} pieces</h3><ul>{[...summary].map(([name,count])=><li key={name}>{count} × {name}</li>)}</ul>
 {!pieces.length&&<p className="muted">Piece details unavailable.</p>}
 <EvidenceGallery files={evidence} />
 {!["Completed","Failed"].includes(stop.status)&&<details className="pickup-photos"><summary className="button secondary">Take / upload receiving photos</summary><EvidenceUpload config={{jobId:job.id,pickReturnStopId:stop.id,type:"Receiving Evidence",defaultVisibility:"internal",photoOnly:true}} button="Save receiving photo" accept="image/*" /></details>}
 <PickupStopControls nextStop={visible[index+1]?.id} stop={stop.id} status={stop.status} waitUntil={stop.pickup_wait_until} coming={stop.customer_coming_at} blocked={blocked} hasEvidence={evidence.length>0} phone={customer?.phone||stop.customer_phone} />
 </article>;
 })}
 {(routes??[]).map(route=>{
 const all=(stops??[]).filter(s=>s.route_id===route.id);const ready=all.length>0&&all.every(s=>["Completed","Failed","Cancelled"].includes(s.status));
 return route.confirmed_at?<p className="notice success" key={route.id}>Arrival at shop confirmed.</p>:<div className="pickup-route-end" key={route.id}><p>The route stays open until arrival at the shop is confirmed.</p>{ready?<Form operation="route-confirm" hidden={{route_id:route.id}} fields={[]} back={`/pick-return/pickup?date=${date}`} button={all.every(s=>s.status==="Cancelled")?"Close interrupted route":"Confirm arrival at shop"} />:<button disabled>Confirm arrival at shop · finish stops first</button>}</div>;
 })}
 </section>;
}
