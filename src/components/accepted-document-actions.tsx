"use client";
import { useActionState } from "react";
import { mutate } from "@/app/actions";
export function AcceptedDocumentActions({id,back}:{id:string;back:string}) {
  const [state, action, pending] = useActionState(mutate.bind(null,"accepted-document",back),{});
  return <form action={action}>
    <input type="hidden" name="id" value={id}/>
    <label>Document action
      <select name="part" defaultValue="process">
        <option value="process">Process PDF / pending copies</option>
        <option value="pdf">Retry failed PDF generation</option>
        <option value="customer">Retry failed customer copy</option>
        <option value="authorize-live">Authorize live copies of this document</option>
        <option value="internal">Retry failed ToolTag copy</option>
      </select>
    </label>
    <label className="checkbox"><input type="checkbox" name="reconciled"/>I confirm the selected send to the real recipient; I reviewed Gmail Sent to avoid duplicates.</label>
    <button disabled={pending}>{pending ? "Processing…" : "Apply"}</button>
    {state.error && <p role="alert" className="notice error">{state.error}</p>}
    {state.mailStatus && <p role="status" className="notice">{state.mailStatus}</p>}
  </form>;
}
