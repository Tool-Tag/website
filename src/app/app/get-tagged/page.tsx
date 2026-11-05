import {RecordList} from "@/components/record-list";
import {paginateList} from "@/lib/domain/list-pagination";
import {denverDateTime} from "@/lib/domain/time";
import Link from "next/link";
import { requirePermission } from "@/lib/domain/context";
import { Heading, Panel, Empty } from "@/components/ui";

export const dynamic = "force-dynamic";

type GetTaggedAttentionRow = {
  id: string;
  reference: string;
  name: string;
  service_method?: string | null;
  created_at: string;
  request_status: string;
  matching: string;
};

export default async function GetTaggedRequestsPage({searchParams}:{searchParams:Promise<{tab?:string;page?:string}>}) {
  const search=await searchParams,history=search.tab==="history";
  const { db } = await requirePermission("quotes.view");
  const { data, error } = await db.rpc(history?"get_tagged_history":"get_tagged_attention");

  if (error) {
    return (
      <>
        <Heading title="Get Tagged Requests" />
        <p className="notice error">{error.message}</p>
      </>
    );
  }

  const requests = (Array.isArray(data) ? data : []) as GetTaggedAttentionRow[];

  const paging=paginateList(requests,search.page);
  const pageUrl=(page:number)=>`/app/get-tagged?tab=${history?"history":"pending"}&page=${page}`;
  return (
    <>
      <Heading
        title="Get Tagged Requests"
        subtitle="Public requests waiting for review and pricing."
      />

      <nav className="main-tab-list" aria-label="Request status"><Link href="/app/get-tagged" className={`main-tab ${history?"":"active"}`}>Pending</Link><Link href="/app/get-tagged?tab=history" className={`main-tab ${history?"active":""}`}>History</Link></nav>
      {requests.length ? (
        <Panel><RecordList label="Get Tagged Request" empty="No requests in this view." rows={paging.items.map(request=>({id:request.id,title:request.name,reference:request.reference,description:`${request.service_method||'Service to be confirmed'} · ${denverDateTime(request.created_at)}`,status:request.request_status,icon:'request',details:[{label:'Reference',value:request.reference},{label:'Received',value:denverDateTime(request.created_at)},{label:'Service',value:request.service_method||'To be confirmed'},{label:'Customer matching',value:request.matching},{label:'Status',value:request.request_status}],actions:[{label:'Review Request',href:`/app/get-tagged/${request.id}`}]}))}/></Panel>
      ) : (
        <Empty>No Get Tagged requests need attention.</Empty>
      )}
      <nav className="actions pagination" aria-label="Request pages">{paging.page>1?<Link className="button menu-link-gold" href={pageUrl(paging.page-1)}>Previous</Link>:<button disabled>Previous</button>}<span>Page {paging.page} of {paging.pages}</span>{paging.page<paging.pages?<Link className="button menu-link-gold" href={pageUrl(paging.page+1)}>Next</Link>:<button disabled>Next</button>}</nav>
    </>
  );
}
