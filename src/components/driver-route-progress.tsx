import Link from 'next/link';
import {routeDateLabel} from '@/lib/domain/driver-dates';
import {HexIcon} from './hex-icon';
export type DriverProgressStop={id:string;status:string;job:string;address:string};
/** Existing route sequence/status is displayed without advancing or changing any stop. */
export function DriverRouteProgress({leg,date,stops}:{leg:'pickup'|'return';date:string;stops:DriverProgressStop[]}){
 const done=stops.filter(stop=>stop.status==='Completed').length;
 const next=stops.find(stop=>!['Completed','Failed','Cancelled'].includes(stop.status));
 const pickup=leg==='pickup';
 return <><header className="driver-progress-header"><Link className="menu-link-gold button secondary" href="/pick-return">← All routes</Link><p className="eyebrow">TOOLTAG / {pickup?'PICK UP':'DELIVERY'} ROUTE</p><h1>{routeDateLabel(date)}</h1><p className="driver-window">{pickup?'8:00 AM–12:00 PM':'2:00 PM–6:00 PM'} · Denver time</p><div className="driver-progress-count"><strong>{done}/{stops.length} {pickup?'picked up':'delivered'}</strong><span>{stops.length?Math.round(done/stops.length*100):0}% complete</span></div><div className="driver-segments" aria-label={`${done} of ${stops.length} stops completed`}>{stops.map(stop=><span key={stop.id} className={stop.status==='Completed'?'done':stop.id===next?.id?'current':''}/>)}</div></header>
 {next&&<a className="driver-next-preview" href={`#${leg}-stop-${next.id}`}><HexIcon name="route"/><span><small>{next.status==='Arrived'?'AT THIS STOP':'NEXT STOP'} · {stops.indexOf(next)+1}</small><strong>{next.job}</strong><span>{next.address||'Address available in stop details'}</span></span><span aria-hidden="true">↓</span></a>}
 </>;
}
