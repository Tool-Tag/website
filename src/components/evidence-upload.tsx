"use client";
import {HexModalFrame,ModalActions} from "./hex-modal-frame";

import {ModalClose} from "./modal-close";
import Image from "next/image";
import {usePhotoSelection} from "./use-photo-selection";
import {photoAccept} from "@/lib/photos/normalize";
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

  const photo=usePhotoSelection(config.expenseProof?expenseProofError:undefined);
  const driverPhoto=Boolean(config.pickReturnStopId&&config.photoOnly);
  const [capture,setCapture]=useState(false),[preview,setPreview]=useState('');
  useEffect(()=>()=>{if(preview)URL.revokeObjectURL(preview);},[preview]);
  const input = useRef<HTMLInputElement>(null);
  const approved = useRef(false);
  const openPicker = () => {approved.current = true; input.current?.click(); approved.current = false;};
  const [warning, setWarning] = useState(false);
  const warn = !driverPhoto && (config.type === "Receiving Evidence" || config.type === "Delivery Evidence");

  const router=useRouter();
  useEffect(()=>{if(state.ok&&state.documentId){onStored?.(state.documentId);if(!config.expenseProof)router.refresh();}},[state.ok,state.documentId,router,onStored,config.expenseProof]);
  if (!canAny(access,evidencePermissions(config.type,Boolean(config.pickReturnStopId)))) return null;
  return (
    <form action={action} className="evidence-upload">
      <div className="photo-choice-buttons">
        {driverPhoto&&<><button type="button" disabled={pending||photo.preparing} onClick={()=>{setCapture(true);input.current?.setAttribute('capture','environment');input.current?.click();}}>Take photo</button><button type="button" disabled={pending||photo.preparing} onClick={()=>{setCapture(false);input.current?.removeAttribute('capture');input.current?.click();}}>Upload</button></>}<label hidden={driverPhoto}>Upload file<input hidden={driverPhoto} capture={driverPhoto&&capture?"environment":undefined} ref={input} onClick={(event) => {if(warn && !approved.current){event.preventDefault();setWarning(true);}}} onChange={async e=>{const element=e.currentTarget;await photo.onChange(e);const file=element.files?.[0];if(driverPhoto&&file&&element.validity.valid)setPreview(URL.createObjectURL(file));}} name="file" type="file" required disabled={pending||photo.preparing} accept={photoAccept(accept ?? (config.photoOnly ? "image/*" : undefined))}/></label>
      </div>
      {driverPhoto&&preview&&<Image unoptimized src={preview} alt="Selected evidence preview" width={280} height={180}/> }
      {warning && <div className="delivery-ack-backdrop"><section className="delivery-ack-panel" role="dialog" aria-modal="true" aria-labelledby="photo-warning-title"><HexModalFrame>
        <ModalClose type="button" className="modal-close" aria-label="Close photo guidance" onClick={()=>setWarning(false)}>×</ModalClose><h2 id="photo-warning-title">Item evidence</h2>
        <p>Take clear photos of every side of each item, including existing damage and work details.</p>
        <p className="notice">Missing photos may result in charges under the service policies. Review the evidence before continuing.</p>
        <ModalActions><button type="button" onClick={() => {setWarning(false); openPicker();}}>Understood · continue</button>
        <button type="button" className="secondary" onClick={() => setWarning(false)}>Cancel</button></ModalActions>
      </HexModalFrame></section></div>}

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
        {driverPhoto?"Driver note (optional)":"Notes (optional)"}
        <textarea name="notes" rows={2} maxLength={2000} />
      </label>

      {photo.preparing&&<p role="status">Preparing your photo…</p>}{photo.error&&<p className="notice error" role="alert">{photo.error}</p>}
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

      <button disabled={pending||photo.preparing}>{pending ? "Uploading…" : button}</button>
    </form>
  );
}
