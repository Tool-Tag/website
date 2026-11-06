"use client";
import {useState,type ReactNode} from "react";
/** Mount editable controls only when their section is expanded, keeping their
 * modal footer actions out of view while the disclosure is closed. */
export function SettingsDisclosure({title,children}:{title:string;children:ReactNode}){
 const [open,setOpen]=useState(false);
 return <details onToggle={event=>setOpen(event.currentTarget.open)}><summary>{title}</summary>{open&&children}</details>;
}
