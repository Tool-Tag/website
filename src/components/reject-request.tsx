"use client";
import {useActionState,useEffect,useRef} from "react";
import {useRouter} from "next/navigation";
import {mutate,type ActionState} from "@/app/actions";
import {DialogClose} from "./dialog-close";
export function RejectRequest({id}:{id:string}) {
 const ref=useRef<HTMLDialogElement>(null),router=useRouter();
 const [state,action,pending]=useActionState<ActionState,FormData>(mutate.bind(null,"get-tagged-reject",""),{});
 useEffect(()=>{if(state.ok){ref.current?.close();router.push("/app/get-tagged?tab=history");router.refresh();}},[state,router]);
 return <><button type="button" className="menu-link-blue-electric" onClick={()=>ref.current?.showModal()}>Reject</button>
 <dialog ref={ref} className="action-modal" aria-labelledby="reject-request-title"><DialogClose/><h2 id="reject-request-title">Reject Request</h2>
 <p>The request and its unsent Draft Quote move to History. The customer receives your reason by email.</p>
 <form action={action} className="stack"><input type="hidden" name="id" value={id}/><label>Rejection reason<textarea name="reason" required minLength={1} maxLength={2000} disabled={pending}/></label>
 {state.error&&<p role="alert" className="notice error">{state.error}</p>}<button disabled={pending}>{pending?"Saving…":"Reject Request"}</button></form></dialog></>;
}
