import Link from "next/link";
import {context} from "@/lib/domain/context";
import {denverTime} from "@/lib/domain/time";
import {routeDateLabel} from "@/lib/domain/driver-dates";
import {ReturnStopControls} from "@/components/return-stop-controls";
import {EvidenceUpload} from "@/components/evidence-upload";
import {EvidenceGallery} from "@/components/evidence-gallery";
import {Form} from "@/components/form";
import {StatusRefresh} from "@/components/status-refresh";
export async function ReturnRoute({date}:{date:string}){
 const {db,unit}=await context();
 const {data:routes,error}=await db.from("pick_return_routes").select("*").eq("unit_id",unit).eq("leg","Return").eq("route_date",date);
 if(error)throw new Error("Could not load Return routes");
 const ids=(routes??[]).map(r=>r.id);
 const {data:stops,error:stopError}=ids.length?await db.from("pick_return_stops").select("*").eq("unit_id",unit).in("route_id",ids).neq("status","Cancelled").order("sequence"):{data:[],error:null};
 if(stopError)throw new Error("Could not load Return stops");
 const jobIds=(stops??[]).map(s=>s.job_id);
 const results=jobIds.length?await Promise.all([
 db.from("pick_return_orders").select("*").eq("unit_id",unit).in("job_id",jobIds).in("service_method",["Pickup & Delivery","Drop-off + Delivery"]).not("production_ready_at","is",null),
 db.from("jobs").select("*").eq("unit_id",unit).in("id",jobIds),
 db.from("quote_logistics").select("quote_id,delivery_address").eq("unit_id",unit),
 db.from("job_items").select("job_id,article,sequence,stage").eq("unit_id",unit).in("job_id",jobIds).order("sequence"),
 db.from("documents").select("*").eq("unit_id",unit).in("job_id",jobIds).eq("type","Delivery Evidence").eq("status","Available"),
 db.from("commercial_flows").select("id,customer_id").eq("unit_id",unit),
 db.from("customers").select("id,name,phone").eq("unit_id",unit),
 db.from("job_extensions").select("job_id,status").eq("unit_id",unit).in("job_id",jobIds),
 db.from("job_commercial_totals").select("id,balance_due").eq("unit_id",unit).in("id",jobIds)
 ]):[];
 if(results.some(r=>r.error))throw new Error("Could not load Return details");
 const [orders,jobs,logistics,items,documents,flows,customers,extensions,balances]=results.map(r=>r.data??[]);
 const allowed=new Set((orders??[]).filter(o=>o.return_status=== "Delivery In Progress" || (o.return_window_start&&new Date(o.return_window_start).toLocaleDateString("en-CA",{timeZone:"America/Denver"})===date)).map(o=>o.job_id));
 const visible=(stops??[]).filter(s=>allowed.has(s.job_id)&&(items??[]).some(i=>i.job_id===s.job_id)&&((items??[]).filter(i=>i.job_id===s.job_id).every(i=>["Finished","Cancelled"].includes(i.stage))||(extensions??[]).some(x=>x.job_id===s.job_id&&["Requested","Draft","Sent","Approved"].includes(x.status))));
 const acknowledgments=new Map<string,string>();
 for(const stop of visible.filter(s=>s.status==="Completed")){const r=await db.rpc("return_acknowledgment_link",{p_stop:stop.id});if(r.error)throw new Error("Could not load delivery acknowledgment");if(r.data)acknowledgments.set(stop.id,r.data);}
 return <section className="return-route driver-landing"><StatusRefresh />
 <Link className="button secondary" href="/pick-return">← All routes</Link><p className="eyebrow">SUNDAY / RETURN</p><h1>{routeDateLabel(date)}</h1><p className="driver-window">2:00 PM–6:00 PM · Denver time</p><p>{visible.filter(s=>s.status==="Completed").length}/{visible.length} delivered</p>
 {!visible.length&&<div className="panel"><h2>No ready Returns</h2><p>Only completed jobs with a delivery leg appear here.</p></div>}
 {visible.map((stop,index)=>{
 const job=(jobs??[]).find(j=>j.id===stop.job_id);if(!job)return null;
 const flow=(flows??[]).find(f=>f.id===job.flow_id);const customer=(customers??[]).find(c=>c.id===flow?.customer_id);
 const evidence=(documents??[]).filter(d=>d.pick_return_stop_id===stop.id);
 const pieces=(items??[]).filter(i=>i.job_id===job.id&&i.stage!=="Cancelled");const summary=new Map<string,number>();pieces.forEach(i=>summary.set(i.article,(summary.get(i.article)??0)+1));
 const blocked=job.status==="Cancelled"||/Cancellation Requested|Production Hold/.test(job.work_stage??"")||(extensions??[]).some(x=>x.job_id===job.id&&["Requested","Draft","Sent"].includes(x.status))||pieces.some(i=>i.stage!=="Finished");
 return <article id={`return-stop-${stop.id}`} className="driver-card return-stop" key={stop.id}><div className="driver-card-heading"><span className="driver-icon">{index+1}</span><div><h2>{customer?.name??"Customer"}</h2><p>{job.code} · {stop.status==="Completed"?"Delivered":stop.status==="Requested"?"Pending · second Return payment":stop.status==="Scheduled"?"Return Scheduled":stop.status==="En Route"?"Return En Route":stop.status}</p></div></div>
 {customer?.phone&&<a className="button secondary" href={`tel:${customer.phone.replace(/[^+0-9]/g,"")}`}>{customer.phone}</a>}
 <p className="return-address">{stop.address||(logistics??[]).find(l=>l.quote_id===job.quote_id)?.delivery_address||"Delivery address unavailable"}</p><p>Window: 2:00 PM–6:00 PM</p>{stop.eta&&<p><strong>ETA: {denverTime(stop.eta)}</strong></p>}
 <h3>{pieces.length} pieces</h3><ul>{[...summary].map(([name,count])=><li key={name}>{count} × {name}</li>)}</ul>
 {!pieces.length&&<p className="muted">Piece details unavailable.</p>}
 <EvidenceGallery files={evidence} />
 {!["Completed","Failed"].includes(stop.status)&&<details className="return-photos"><summary className="button secondary">Take / upload delivery photos</summary><EvidenceUpload config={{jobId:job.id,pickReturnStopId:stop.id,type:"Delivery Evidence",defaultVisibility:"customer",photoOnly:true}} button="Save delivery photo" accept="image/*" /></details>}
 <ReturnStopControls nextStop={visible[index+1]?.id} stop={stop.id} status={stop.status} waitUntil={stop.return_wait_until} coming={stop.return_customer_coming_at} blocked={blocked} hasEvidence={evidence.length>0} phone={customer?.phone||stop.customer_phone} cash={(orders??[]).find(o=>o.job_id===job.id)?.delivery_payment_method==="Cash"} balance={Number((balances??[]).find(b=>b.id===job.id)?.balance_due??0)} ackToken={acknowledgments.get(stop.id)} retryExpires={(orders??[]).find(o=>o.job_id===job.id)?.return_reservation_expires_at} />
 </article>;
 })}
 {(routes??[]).map(route=>{
 const all=(stops??[]).filter(s=>s.route_id===route.id);const ready=all.length>0&&all.every(s=>["Completed","Failed","Cancelled"].includes(s.status));
 return route.confirmed_at?<p className="notice success" key={route.id}>All deliveries confirmed.</p>:<div className="return-route-end" key={route.id}><p>The route stays open until all deliveries are confirmed.</p>{ready?<Form operation="route-confirm" hidden={{route_id:route.id}} fields={[]} back={`/pick-return/return?date=${date}`} button="Confirm all delivered" />:<button disabled>Confirm all delivered · finish stops first</button>}</div>;
 })}
 </section>;
}
