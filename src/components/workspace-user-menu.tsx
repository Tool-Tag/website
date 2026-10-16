"use client";
import Link from "next/link";
import {useEffect,useId,useRef,useState} from "react";

export type UserMenuLink={label:string;href:string};
export function WorkspaceUserMenu({name,links}:{name:string;links:UserMenuLink[]}) {
 const [open,setOpen]=useState(false),id=useId();
 const root=useRef<HTMLDivElement>(null),trigger=useRef<HTMLButtonElement>(null);
 useEffect(()=>{
  if(!open)return;
  const outside=(event:PointerEvent)=>{if(!root.current?.contains(event.target as Node))setOpen(false);};
  const escape=(event:KeyboardEvent)=>{if(event.key==="Escape"){setOpen(false);trigger.current?.focus();}};
  document.addEventListener("pointerdown",outside);
  document.addEventListener("keydown",escape);
  return ()=>{document.removeEventListener("pointerdown",outside);document.removeEventListener("keydown",escape);};
 },[open]);
 return <div ref={root} className="workspace-user-menu">
  <button ref={trigger} type="button" className="secondary workspace-user-trigger" aria-expanded={open} aria-controls={id} title={`User: ${name}`} onClick={()=>setOpen(value=>!value)}>User: {name}<span aria-hidden="true"> ▾</span></button>
  {open&&<nav id={id} className="workspace-user-dropdown" aria-label="User menu">{links.map(link=><Link key={link.href} href={link.href} onClick={()=>setOpen(false)}>{link.label}</Link>)}</nav>}
 </div>;
}
