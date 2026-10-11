"use client";
import {denverDateTime} from "@/lib/domain/time";
import {jobTimelineProgress} from "@/lib/domain/customer-route-tracking";
export function StatusTimeline({steps,current,updated,finished,total}:{steps:string[];current:string;updated:string;finished:number;total:number}){
 const progress=jobTimelineProgress(steps,current);
 const chain=(items:string[],done:boolean)=>items.map(step=><div key={step} className={`status-step${done?" complete":""}`}><span className="status-dot" aria-hidden="true">{done?"✓":"○"}</span><strong title={step}>{step}</strong></div>);
 return <><div className="status-tracker compact-tracker" aria-label="Job progress"><details><summary>✓ Completed… ({progress.done.length})</summary>{chain(progress.done,true)}</details><div className="status-step active"><span className="status-dot" aria-hidden="true">●</span><strong title={current}>Current · {current}{current==="Engraving"&&total>0?` · ${finished}/${total} pieces`:""}</strong></div><details><summary>○ Upcoming… ({progress.upcoming.length})</summary>{chain(progress.upcoming,false)}</details></div><label className="tracking-progress">Job progress: {progress.percentage}%<progress max={100} value={progress.percentage} style={{width:"100%"}} /></label><p className="muted status-updated tracking-progress">Last updated: {denverDateTime(updated)}</p></>;
}
