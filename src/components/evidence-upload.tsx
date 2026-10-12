"use client";
import { useAccess } from "./permission-provider";
import { canAny, evidencePermissions } from "@/lib/auth/permissions";

import {useRouter} from "next/navigation";
import { useEffect, useActionState, useRef, useState } from "react";
import {
  registerEvidenceAction,
  type EvidenceRegistration,
} from "@/app/evidence-actions";

export function EvidenceUpload({
  config,
  button = "Upload File",
  accept,
}: {
  config: EvidenceRegistration;
  button?: string;
  accept?: string;
}) {
  const access = useAccess();
  const [state, action, pending] = useActionState(
    registerEvidenceAction.bind(null, config),
    {},
  );

  const input = useRef<HTMLInputElement>(null);
  const approved = useRef(false);
  const openPicker = () => {approved.current = true; input.current?.click(); approved.current = false;};
  const [choice, setChoice] = useState<"camera" | "file" | null>(null);
  const [warning, setWarning] = useState<"camera" | "file" | null>(null);
  const warn = config.type === "Receiving Evidence" || config.type === "Delivery Evidence";
  const choose = (next: "camera" | "file") => { setChoice(next); if (warn) setWarning(next); else window.setTimeout(openPicker, 0); };
  const router=useRouter();
  useEffect(()=>{if(state.ok)router.refresh();},[state.ok,router]);
  if (!canAny(access,evidencePermissions(config.type,Boolean(config.pickReturnStopId)))) return null;
  return (
    <form action={action} className="evidence-upload">
      <div className="photo-choice-buttons">
        {config.photoOnly && <button type="button" disabled={pending} onClick={() => choose("camera")}>Take photo</button>}
        <button type="button" className="secondary" disabled={pending} onClick={() => choose("file")}>Choose file</button>
        <input ref={input} onClick={(event) => {if(warn && !approved.current){event.preventDefault(); setWarning(choice ?? "file");}}} name="file" type="file" required accept={accept} capture={choice === "camera" ? "environment" : undefined} />
      </div>
      {warning && <div className="delivery-ack-backdrop"><section className="delivery-ack-panel" role="dialog" aria-modal="true" aria-labelledby="photo-warning-title">
        <h2 id="photo-warning-title">Evidencia de las piezas</h2>
        <p>Toma fotos claras de todos los ángulos de cada pieza, incluyendo daños existentes y detalles del trabajo.</p>
        <p className="notice">Si no registras las fotos, pueden aplicarse cargos conforme a las políticas del servicio. Verifica la evidencia antes de continuar.</p>
        <button type="button" onClick={() => {setWarning(null); window.setTimeout(openPicker, 0);}}>Entendido · continuar</button>
        <button type="button" className="secondary" onClick={() => setWarning(null)}>Cancelar</button>
      </section></div>}

      <label>
        Visibility
        <select
          name="visibility"
          defaultValue={config.defaultVisibility ?? "internal"}
        >
          <option value="internal">Internal</option>
          <option value="customer">Customer</option>
        </select>
      </label>

      <label className="wide">
        Notes (optional)
        <textarea name="notes" rows={2} maxLength={2000} />
      </label>

      {state.error && (
        <p className="notice error wide" role="alert">
          {state.error}
        </p>
      )}

      {state.ok && (
        <p className="notice success wide" role="status">
          File stored in Supabase Storage and linked to this record.
        </p>
      )}

      <button disabled={pending}>{pending ? "Uploading…" : button}</button>
    </form>
  );
}
