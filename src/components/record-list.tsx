"use client";
import {useRef,useState} from 'react';
import Link from 'next/link';
import {HexIcon} from './hex-icon';
import {HexModalFrame,ModalActions} from './hex-modal-frame';
import {ModalClose} from './modal-close';
import {Badge} from './ui';
export type RecordListRow={id:string;title:string;reference:string;description:string;status:string;icon?:string;details:{label:string;value:string}[];actions:{label:string;href:string}[]};
/** The list/modal is presentation only; every action goes to its existing authenticated flow. */
export function RecordList({rows,label,empty}:{rows:RecordListRow[];label:string;empty:string}){
 const [selected,setSelected]=useState<RecordListRow|null>(null);const dialog=useRef<HTMLDialogElement>(null);
 return <><ul className="hex-record-list" aria-label={label}>{!rows.length&&<li className="empty">{empty}</li>}{rows.map(row=><li key={row.id}><button type="button" className="hex-record-row" aria-haspopup="dialog" onClick={()=>{setSelected(row);dialog.current?.showModal();}}><HexIcon name={row.icon??'request'}/><span className="hex-record-summary"><strong>{row.title}</strong><small>{row.reference} · {row.description}</small></span><Badge>{row.status}</Badge><span className="row-chevron" aria-hidden="true">›</span></button></li>)}</ul><dialog ref={dialog} className="hex-dialog hex-record-dialog" aria-label={`${label} details`}><ModalClose onClick={()=>dialog.current?.close()}/><HexModalFrame><header><p className="eyebrow">{label}</p><h2>{selected?.title}</h2><p className="muted">{selected?.reference}</p></header>{selected&&<><dl className="hex-detail-grid">{selected.details.map(field=><div key={field.label}><dt>{field.label}</dt><dd>{field.value}</dd></div>)}</dl><ModalActions>{selected.actions.map(action=><Link className="button" key={action.href} href={action.href}>{action.label}</Link>)}</ModalActions></>}</HexModalFrame></dialog></>;
}
