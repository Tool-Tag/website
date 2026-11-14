import Link from 'next/link';
import {HexIcon} from './hex-icon';
import {routeDateLabel} from '@/lib/domain/driver-dates';
export type DriverRouteOption={leg:'pickup'|'return';date:string;total:number;completed:number};
/** Presentation only; the server supplies the existing scoped route counts and dates. */
export function DriverRouteSelection({selected,routes}:{selected:string;routes:DriverRouteOption[]}){
 return <section className="driver-landing driver-route-selection"><header className="driver-selection-heading"><p className="eyebrow">TOOLTAG / ON THE ROAD</p><h1>Pick up and Delivery</h1><p className="muted">Choose your route. One stop at a time.</p></header>
 <form className="driver-date panel" action="/pick-return"><HexIcon name="clock"/><label htmlFor="route-day">View another day<input id="route-day" type="date" name="date" defaultValue={selected} required/></label><button className="secondary menu-link-gold">View routes</button></form>
 <div className="driver-cards">{routes.map(route=>{const pickup=route.leg==='pickup';return <Link className={`driver-card driver-${route.leg}`} key={route.leg} href={`/pick-return/${route.leg}?date=${route.date}`}><div className="driver-card-heading"><HexIcon name="route"/><h2>{pickup?'Pick up':'Delivery'}</h2><span className="driver-leg-label">{pickup?'COLLECT':'DELIVER'}</span></div><p className="driver-route-date">{routeDateLabel(route.date)}</p><p className="driver-window">{pickup?'8:00 AM–12:00 PM':'2:00 PM–6:00 PM'}<span>Denver time</span></p><div className="driver-stats"><strong>{route.total} stops</strong><span>{route.completed}/{route.total} completed</span></div><progress value={route.completed} max={route.total||1} aria-label={`${pickup?'Pickup':'Delivery'} route progress`}/><span className="driver-open">Open {pickup?'pickup':'delivery'} route <span aria-hidden="true">→</span></span></Link>;})}</div></section>;
}
