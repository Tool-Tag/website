"use client";
import Link from 'next/link';
import {useRef,useState} from 'react';
import {SHOP_FLOOR_STAGES,shopFloorGroups,type ShopFloorStage} from '@/lib/domain/shop-floor';
import {denverDateTime,TOOLTAG_TIMEZONE} from '@/lib/domain/time';
import {ModalClose} from './modal-close';
import {HexModalFrame,ModalActions} from './hex-modal-frame';
import {HexIcon} from './hex-icon';
export type ShopFloorJob={id:string;code:string;customer:string;stage:ShopFloorStage;arrival:string|null;arrivalSort:string;items:{article:string;stage:string;sequence:number}[];notes:string};
const actions:Record<ShopFloorStage,string>={'Reception':'Review reception','Verification':'Verify pieces','Falcon Queue':'Open Falcon work','In Process':'Continue work','Ready for pickup/delivery':'Review handover'};
const arrivalLabel=(value:string)=>new Intl.DateTimeFormat('en-US',{timeZone:TOOLTAG_TIMEZONE,month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}).format(new Date(value));
export function ShopFloorBoard({jobs}:{jobs:ShopFloorJob[]}){
 const [filter,setFilter]=useState<ShopFloorStage|'All stages'>('All stages');
 const [selected,setSelected]=useState<ShopFloorJob|null>(null),dialog=useRef<HTMLDialogElement>(null);
 const groups=shopFloorGroups(jobs,filter);
 return <div className={`shop-floor-board ${filter==='All stages'?'board-all':'board-filtered'}`}>
 <nav className="shop-floor-filters main-tab-list" aria-label="Shop Floor stages">{(['All stages',...SHOP_FLOOR_STAGES] as const).map(stage=><button key={stage} type="button" className={`main-tab ${filter===stage?'active':''}`} aria-pressed={filter===stage} onClick={()=>setFilter(stage)}>{stage}<span className="tab-count">{stage==='All stages'?jobs.length:jobs.filter(job=>job.stage===stage).length}</span></button>)}</nav>
 {groups.map(group=><section key={group.stage} className="shop-floor-section" aria-label={group.stage}><header><div><p className="eyebrow">SHOP FLOOR · {SHOP_FLOOR_STAGES.indexOf(group.stage)+1} / 5</p><h2>{group.stage}</h2></div><span className="shop-floor-order">Oldest arrival first <span className="badge">{group.jobs.length}</span></span></header><div className="shop-floor-grid">{group.jobs.map(job=>{const complete=job.items.filter(item=>item.stage==='Finished').length;return <button key={job.id} type="button" className="shop-floor-card" aria-haspopup="dialog" onClick={()=>{setSelected(job);dialog.current?.showModal();}}><div className="shop-floor-card-heading"><HexIcon name="job"/><strong>{job.code}</strong></div><h3>{job.customer}</h3><time className="arrived" dateTime={job.arrival??job.arrivalSort}>{job.arrival?`Arrived ${arrivalLabel(job.arrival)}`:`Arrival not recorded · Created ${arrivalLabel(job.arrivalSort)}`}</time><div className="shop-piece-count"><span>{job.items.length} pieces</span><span>{complete}/{job.items.length} finished</span></div><progress value={complete} max={job.items.length||1} aria-label={`${job.code} piece progress`}/><span className="shop-card-action">{actions[group.stage]} <span aria-hidden="true">↗</span></span></button>;})}{!group.jobs.length&&<p className="empty">No jobs in this stage.</p>}</div></section>)}
 <dialog ref={dialog} className="hex-dialog shop-floor-dialog" aria-label="Shop Floor job details"><ModalClose onClick={()=>dialog.current?.close()}/><HexModalFrame><header><p className="eyebrow">Shop Floor · {selected?.stage}</p><h2>{selected?.code}</h2><p className="muted">{selected?.customer}</p></header>{selected&&<><p>{selected.arrival?`Arrived ${denverDateTime(selected.arrival)}`:`Arrival not recorded · Created ${denverDateTime(selected.arrivalSort)}`}</p><h3>Pieces</h3><ol className="shop-floor-items">{[...selected.items].sort((a,b)=>a.sequence-b.sequence).map((item,i)=><li key={i}><strong>{item.article}</strong><span className="badge">{item.stage}</span></li>)}</ol><h3>Full notes</h3><p style={{whiteSpace:'pre-wrap'}}>{selected.notes||'No additional notes.'}</p><ModalActions><Link className="button" href={`/app/jobs/${selected.id}`}>{actions[selected.stage]}</Link></ModalActions></>}</HexModalFrame></dialog>
 </div>;
}
