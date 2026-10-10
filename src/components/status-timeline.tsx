"use client";
import {denverDateTime} from "@/lib/domain/time";
export function StatusTimeline({steps, current, updated, finished, total}: {steps: string[]; current: string; updated: string; finished: number; total: number}) {
  const operationalStage = ["Pending Delivery", "Shop Pickup"].includes(current) ? "Delivery In Progress" : current;
  const index = Math.max(0, steps.indexOf(operationalStage) >= 0 ? steps.indexOf(operationalStage) : steps.indexOf("Final Details"));
  const completed = current === "Completed" ? steps.length : index;
  const percentage = steps.length ? Math.round(completed / steps.length * 100) : 0;
  const chain = (items: string[], done: boolean) => items.map(step => <div key={step} className={`status-step${done ? " complete" : ""}`}><span className="status-dot">{done ? "✓" : "○"}</span><strong>{step}</strong></div>);
  return <><div className="status-tracker" aria-label="Job progress">
    <details><summary>✓ Done… ({index})</summary>{chain(steps.slice(0,index), true)}</details>
    <div className="status-step active"><span className="status-dot">●</span><strong>{current}{current === "Engraving" && total > 0 ? ` · ${finished}/${total}` : ""}</strong></div>
    <details><summary>○ Upcoming… ({Math.max(0,steps.length-index-1)})</summary>{chain(steps.slice(index+1), false)}</details>
  </div><label>Progress: {percentage}%<progress max={100} value={percentage} style={{width:"100%"}} /></label><p className="muted status-updated">Last updated: {denverDateTime(updated)}</p></>;
}
