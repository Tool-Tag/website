"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
export function BackNavigation() {
 const path=usePathname(); const parts=path.split("/").filter(Boolean);
 if(path==="/app") return null;
 let href="/app",label="Home";
 if(parts[1]==="finance") { href=parts.length>3 ? `/app/finance/${parts[2]}` : "/app/finance"; label=parts.length>3 ? "Back to List" : "Finance"; if(path==="/app/finance") {href="/app";label="Home";} }
 else if(parts.length>2) { const names:Record<string,string>={quotes:"Quotes",jobs:"Jobs",customers:"Customers","job-extensions":"Jobs","job-receipts":"Jobs"}; const section=["job-extensions","job-receipts"].includes(parts[1])?"jobs":parts[1]; href=`/app/${section}`;label=names[parts[1]] || "Back to List"; }
 return <p><Link href={href} className="muted" aria-label={`Back to ${label}`}>← {label}</Link></p>;
}
