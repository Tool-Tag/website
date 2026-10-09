"use client";
import { useActionState } from "react";
import { mutate } from "@/app/actions";
export function AcceptedDocumentActions({id,back}:{id:string;back:string}) {
  const [state, action, pending] = useActionState(mutate.bind(null,"accepted-document",back),{});
  return <form action={action}>
    <input type="hidden" name="id" value={id}/>
    <label>Document Action
      <select name="part" defaultValue="process">
        <option value="process">Process PDF / Pending Copies</option>
        <option value="pdf">Retry Failed Generation</option>
        <option value="customer">Retry Failed Customer Copy</option>
        <option value="authorize-live">Authorize Real Copies for This Document</option>
        <option value="internal">Retry Failed ToolTag Copy</option>
      </select>
    </label>
    <label className="checkbox"><input type="checkbox" name="reconciled"/>I confirm the selected delivery to the real recipient; I reviewed Gmail Sent to avoid duplicates.</label>
    <button disabled={pending}>{pending ? "Procesando…" : "Aplicar"}</button>
    {state.error && <p role="alert" className="notice error">{state.error}</p>}
    {state.mailStatus && <p role="status" className="notice">{state.mailStatus}</p>}
  </form>;
}
