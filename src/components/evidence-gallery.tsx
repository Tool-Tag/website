"use client";
import { useRef, useState } from "react";
type Evidence = {id:string;file_name?:string;name?:string};
export function EvidenceGallery({files,publicView=false}:{files:Evidence[];publicView?:boolean}) {
 const dialog=useRef<HTMLDialogElement>(null); const [file,setFile]=useState<Evidence|null>(null);
 return <>
  {!publicView && <><p className="notice">Drive pendiente de configurar. La subida y las vistas previas aún no están activadas.</p><div className="actions"><button type="button" disabled>Subir foto</button><button type="button" disabled className="secondary">Subir archivo</button></div></>}
  <div className="grid two">{files.map(f=><button className="secondary item" type="button" key={f.id} onClick={()=>{setFile(f);dialog.current?.showModal();}}><span aria-hidden="true">▧ </span>{f.file_name || f.name}<small style={{display:"block"}}>Vista previa pendiente</small></button>)}</div>
  {!files.length && <p className="muted">{publicView?"La galería estará disponible cuando se habilite la conexión de archivos.":"Sin archivos registrados."}</p>}
  <dialog ref={dialog} className="quote-dialog"><h2>{file?.file_name || file?.name}</h2><p>La vista previa dentro de ToolTag está pendiente de habilitar. No se ha conectado Google Drive.</p><button type="button" onClick={()=>dialog.current?.close()}>Cerrar</button></dialog>
 </>;
}
