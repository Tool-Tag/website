"use client";
import {useRef,type ReactNode} from 'react';
import {HexModalFrame} from './hex-modal-frame';
import {ModalClose} from './modal-close';
export function DriverStopCard({id,sequence,name,job,address,status,pieces,next,completedLabel='Delivered',children}:{id:string;sequence:number;name:string;job:string;address:string;status:string;pieces:number;next:boolean;completedLabel?:string;children:ReactNode}){
 const dialog=useRef<HTMLDialogElement>(null);
 return <article id={id} className={`driver-stop-summary${next?' next':''}`}><button type="button" className="driver-stop-open" onClick={()=>dialog.current?.showModal()} aria-label={`Stop ${sequence}: ${name}, ${job}`}><span className="driver-icon">{sequence}</span><div><strong>{name}</strong><span className="muted">{job} · {pieces} pieces</span><p>{address||'Address unavailable'}</p><span className="badge" data-tone={next?'gold':'blue'}>{status==='Completed'?completedLabel:status==='Arrived'?'Arrived':next?'Next':['Requested','Scheduled'].includes(status)?'Pending':status}</span></div></button><dialog ref={dialog} className="hex-dialog driver-stop-dialog" aria-label={`Stop details: ${job}`}><ModalClose onClick={()=>dialog.current?.close()}/><HexModalFrame><h2>{name} · {job}</h2>{address&&<a className="button menu-link-gold" href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`} target="_blank" rel="noopener noreferrer">Navigate with Google Maps ↗</a>}{children}</HexModalFrame></dialog></article>;
}
