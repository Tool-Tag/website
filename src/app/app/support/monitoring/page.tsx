import Link from "next/link";
import {paginateList} from "@/lib/domain/list-pagination";
import {requireOwner,rows} from "@/lib/domain/context";
import {Heading,Table,Empty,Badge} from "@/components/ui";
import {Form} from "@/components/form";
import {denverDateTime} from "@/lib/domain/time";
import {isPresentationTest} from "@/lib/domain/presentation";
export const dynamic="force-dynamic";
export default async function Monitoring({searchParams}:{searchParams:Promise<{page?:string}>}){
 await requireOwner();
 const notifications=(await rows("notifications",{order:"created_at",limit:200})).filter(n=>!isPresentationTest(JSON.stringify(n)));
 const pagination=paginateList(notifications,(await searchParams).page);
 return <><Heading title="Delivery Monitoring" subtitle="Customer email notifications"><Link className="button menu-link-gold" href="/app/support">Support</Link></Heading>
 <p className="muted">Sent means the provider accepted the message. Failed or unconfirmed deliveries require review before retrying.</p>
 {notifications.length?<Table headers={["Event","Status","Scheduled","Delivery"]}>{pagination.items.map(n=><tr key={n.id}><td>{String(n.event).replaceAll("_"," ")}</td><td><Badge>{n.status}</Badge></td><td>{denverDateTime(n.due_at)}</td><td>{n.mail_error?"Delivery needs review":n.provider_id?"Accepted by provider":"Pending"}{<details><summary>Retry notification</summary><Form inlineActions operation="retry-notification" hidden={{id:n.id}} fields={[]} back="/app/support/monitoring" button="Authorize Retry"><label className="checkbox"><input name="reconciled" type="checkbox" required/>I verified the recipient and sent messages; retry this notification only.</label></Form></details>}</td></tr>)}</Table>:<Empty/>}
 <nav className="actions pagination" aria-label="Monitoring pages">{pagination.page>1?<Link className="button menu-link-gold" href={`/app/support/monitoring?page=${pagination.page-1}`}>Previous</Link>:<button disabled>Previous</button>}<span>Page {pagination.page} of {pagination.pages}</span>{pagination.page<pagination.pages?<Link className="button menu-link-gold" href={`/app/support/monitoring?page=${pagination.page+1}`}>Next</Link>:<button disabled>Next</button>}</nav></>;
}
