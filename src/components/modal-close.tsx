"use client";
import {useEffect,useRef,useState,type ButtonHTMLAttributes,type CSSProperties} from "react";
/** Remains in its dialog's top layer/focus scope, but sits outside the visible panel. */
export function ModalClose({className="",style,children="×",...props}:ButtonHTMLAttributes<HTMLButtonElement>){
 const button=useRef<HTMLButtonElement>(null),[position,setPosition]=useState<CSSProperties>({top:8,right:8});
 useEffect(()=>{
  const panel=button.current?.closest('dialog,[role="dialog"]');if(!panel)return;
  const update=()=>{const r=panel.getBoundingClientRect();if(!r.width)return;const top=Math.max(6,r.top-18),left=Math.min(window.innerWidth-42,r.right+6);setPosition(old=>old.top===top&&old.left===left?old:{top,left,right:"auto"});};
  const resize=new ResizeObserver(update),mutation=new MutationObserver(update);resize.observe(panel);mutation.observe(panel,{attributes:true,attributeFilter:["open","style","class"]});window.addEventListener("resize",update);window.addEventListener("scroll",update,true);update();
  return()=>{resize.disconnect();mutation.disconnect();window.removeEventListener("resize",update);window.removeEventListener("scroll",update,true);};
 },[]);
 return <button {...props} ref={button} type="button" aria-label={props["aria-label"]||"Close dialog"} className={`modal-close floating-modal-close ${className}`} style={{...style,...position}}>{children}</button>;
}
