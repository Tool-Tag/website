"use client";
import { useActionState } from "react";
import { mutate } from "@/app/actions";
export function AcceptedDocumentActions({id,back}:{id:string;back:string}) {
  const [state, action, pending] = useActionState(mutate.bind(null,"accepted-document",back),{});
  return <form action={action}>
    <input type="hidden" name="id" value={id}/>
    <label>Acción del documento
      <select name="part" defaultValue="process">
        <option value="process">Procesar PDF / copias pendientes</option>
        <option value="pdf">Reintentar generación fallida</option>
        <option value="customer">Reintentar copia cliente fallida</option>
        <option value="internal">Reintentar copia ToolTag fallida</option>
      </select>
    </label>
    <label className="checkbox"><input type="checkbox" name="reconciled"/>Para un envío de resultado incierto: revisé Enviados en Gmail y confirmé que esa copia no fue enviada.</label>
    <button disabled={pending}>{pending ? "Procesando…" : "Aplicar"}</button>
    {state.error && <p role="alert" className="notice error">{state.error}</p>}
    {state.mailStatus && <p role="status" className="notice">{state.mailStatus}</p>}
  </form>;
}
