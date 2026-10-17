"use client";
import type {MouseEvent} from "react";
/** Uses the dialog's own cancel/close handlers, including route-backed modals. */
export function DialogClose() {
 return <button type="button" className="modal-close" aria-label="Close dialog" onClick={(event:MouseEvent<HTMLButtonElement>)=>{
  const dialog=event.currentTarget.closest("dialog");if(!dialog)return;
  const cancel=new Event("cancel",{cancelable:true,bubbles:false});
  if(dialog.dispatchEvent(cancel))dialog.close();
 }}>×</button>;
}
