"use client";
import {ModalClose} from "./modal-close";
import {expenseProofError} from "@/lib/domain/expense-proof";
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
  onStored,
}: {
  config: EvidenceRegistration;
  button?: string;
  accept?: string;
  onStored?: (id:string)=>void;
}) {
  const access = useAccess();
  const [state, action, pending] = useActionState(
    registerEvidenceAction.bind(null, config),
    {},
  );

  const [fileError,setFileError]=useState("");
  const input = useRef<HTMLInputElement>(null);
  const approved = useRef(false);
  const openPicker = () => {approved.current = true; input.current?.click(); approved.current = false;};
  const [choice, setChoice] = useState<"camera" | "file" | null>(null);
  const [warning, setWarning] = useState<"camera" | "file" | null>(null);
  const warn = config.type === "Receiving Evidence" || config.type === "Delivery Evidence";
  const choose = (next: "camera" | "file") => { setChoice(next); if(next==="camera")input.current?.setAttribute("capture","environment");else input.current?.removeAttribute("capture");if (warn) setWarning(next); else openPicker(); };
  const router=useRouter();
  useEffect(()=>{if(state.ok&&state.documentId){onStored?.(state.documentId);if(!config.expenseProof)router.refresh();}},[state.ok,state.documentId,router,onStored,config.expenseProof]);
  if (!canAny(access,evidencePermissions(config.type,Boolean(config.pickReturnStopId)))) return null;
  return (
    <form action={action} className="evidence-upload">
      <div className="photo-choice-buttons">
        {config.photoOnly && <button type="button" disabled={pending} onClick={() => choose("camera")}>Take photo</button>}
        <button type="button" className="secondary" disabled={pending} onClick={() => choose("file")}>Choose file</button>
        <input ref={input} onClick={(event) => {if(warn && !approved.current){event.preventDefault(); setWarning(choice ?? "file");}}} onChange={event=>{if(config.expenseProof){const file=event.target.files?.[0];const error=file?expenseProofError(file):null;setFileError(error??"");if(error)event.target.value="";}}} name="file" type="file" required accept={accept ?? (config.photoOnly ? "image/*" : undefined)} capture={choice === "camera" ? "environment" : undefined} />
      </div>
      {warning && <div className="delivery-ack-backdrop"><section className="delivery-ack-panel" role="dialog" aria-modal="true" aria-labelledby="photo-warning-title">
        <ModalClose type="button" className="modal-close" aria-label="Close photo guidance" onClick={()=>setWarning(null)}>×</ModalClose><h2 id="photo-warning-title">Item evidence</h2>
        <p>Take clear photos of every side of each item, including existing damage and work details.</p>
        <p className="notice">Missing photos may result in charges under the service policies. Review the evidence before continuing.</p>
        <button type="button" onClick={() => {setWarning(null); openPicker();}}>Understood · continue</button>
        <button type="button" className="secondary" onClick={() => setWarning(null)}>Cancel</button>
      </section></div>}

      {config.expenseProof ? <input type="hidden" name="visibility" value="internal"/> : <label>
        Visibility
        <select
          name="visibility"
          defaultValue={config.defaultVisibility ?? "internal"}
        >
          <option value="internal">Internal</option>
          <option value="customer">Customer</option>
        </select>
      </label>}

      <label className="wide">
        Notes (optional)
        <textarea name="notes" rows={2} maxLength={2000} />
      </label>

      {fileError&&<p className="notice error" role="alert">{fileError}</p>}
      {state.error && (
        <p className="notice error wide" role="alert">
          {state.error}
        </p>
      )}

      {state.ok && (
        <p className="notice success wide" role="status">
          {config.expenseProof?"Receipt image uploaded. Save the expense to attach it.":"File stored in Supabase Storage and linked to this record."}
        </p>
      )}

      <button disabled={pending}>{pending ? "Uploading…" : button}</button>
    </form>
  );
}
