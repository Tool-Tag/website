"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
export function BackNavigation() {
 const path=usePathname(); const parts=path.split("/").filter(Boolean);
 if(path==="/app") return null;
 let href="/app",label="Inicio";
 if(parts[1]==="finance") { href=parts.length>3 ? `/app/finance/${parts[2]}` : "/app/finance"; label=parts.length>3 ? "Volver a la lista" : "Finanzas"; if(path==="/app/finance") {href="/app";label="Inicio";} }
 else if(parts.length>2) { const names:Record<string,string>={quotes:"Cotizaciones",jobs:"Trabajos",customers:"Clientes","job-extensions":"Trabajos","job-receipts":"Trabajos"}; const section=["job-extensions","job-receipts"].includes(parts[1])?"jobs":parts[1]; href=`/app/${section}`;label=names[parts[1]] || "Volver a la lista"; }
 return <p><Link href={href} className="muted" aria-label={`Volver a ${label}`}>← {label}</Link></p>;
}
