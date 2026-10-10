"use client";
import {TOOLTAG_TIMEZONE} from "@/lib/domain/time";
import {jobTimelineProgress,spanishTrackingStage} from "@/lib/domain/customer-route-tracking";
export function StatusTimeline({steps,current,updated,finished,total}:{steps:string[];current:string;updated:string;finished:number;total:number}){
 const progress=jobTimelineProgress(steps,current);
 const label=(step:string)=>spanishTrackingStage[step]??"Etapa pendiente";
 const chain=(items:string[],done:boolean)=>items.map(step=><div key={step} className={`status-step${done?" complete":""}`}><span className="status-dot" aria-hidden="true">{done?"✓":"○"}</span><strong>{label(step)}</strong></div>);
 return <><div className="status-tracker" aria-label="Avance del trabajo"><details><summary>✓ Completadas… ({progress.done.length})</summary>{chain(progress.done,true)}</details><div className="status-step active"><span className="status-dot" aria-hidden="true">●</span><strong>Actual · {label(current)}{current==="Engraving"&&total>0?` · ${finished}/${total} piezas`:""}</strong></div><details><summary>○ Próximas… ({progress.upcoming.length})</summary>{chain(progress.upcoming,false)}</details></div><label>Avance del trabajo: {progress.percentage}%<progress max={100} value={progress.percentage} style={{width:"100%"}} /></label><p className="muted status-updated">Última actualización: {new Date(updated).toLocaleString("es-MX",{timeZone:TOOLTAG_TIMEZONE,timeZoneName:"short"})}</p></>;
}
