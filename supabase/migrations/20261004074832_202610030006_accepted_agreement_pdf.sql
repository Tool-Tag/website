-- New acceptances only. Existing agreements, jobs, sales and accepted snapshots are not rewritten.
create table private.agreement_sequences(year integer primary key, value bigint not null);
create table public.accepted_documents (
 id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units,
 document_type text not null default 'Accepted Agreement', agreement_id uuid not null unique references public.agreements,
 customer_id uuid not null references public.customers, quote_id uuid not null unique references public.quotes,
 job_id uuid not null references public.jobs, sale_id uuid references public.sales(transaction_id),
 acceptance_folio text not null unique, agreement_version integer not null, accepted_at timestamptz not null,
 customer_recipient_email text not null, file_name text not null,
 snapshot jsonb not null, canonical_snapshot text not null, acceptance_snapshot_sha256 text not null,
 created_at timestamptz not null default now()
);
create trigger accepted_document_immutable before update or delete on public.accepted_documents for each row execute function private.commercial_immutable();
create table public.accepted_document_status (
 document_id uuid primary key references public.accepted_documents, unit_id uuid not null references public.business_units,
 pdf_status text not null default 'Pending' check(pdf_status in ('Pending','Generating','Ready','PDF Generation Failed')),
 pdf_error text, pdf_claim uuid, pdf_started_at timestamptz, pdf_sha256 text,
 storage_status text not null default 'Pending Drive Upload', drive_file_id text,
 updated_at timestamptz not null default now()
);
create table private.accepted_pdf_artifacts (
 document_id uuid primary key references public.accepted_documents, pdf bytea not null,
 pdf_sha256 text not null, created_at timestamptz not null default now()
);
create trigger accepted_pdf_immutable before update or delete on private.accepted_pdf_artifacts for each row execute function private.commercial_immutable();
revoke all on private.agreement_sequences,private.accepted_pdf_artifacts from public,anon,authenticated,service_role;
alter table public.accepted_documents enable row level security;
alter table public.accepted_document_status enable row level security;
create policy accepted_documents_read on public.accepted_documents for select to authenticated using(private.can_access(unit_id));
create policy accepted_document_status_read on public.accepted_document_status for select to authenticated using(private.can_access(unit_id));
revoke all on public.accepted_documents,public.accepted_document_status from public,anon,authenticated;
grant select on public.accepted_documents,public.accepted_document_status to authenticated;

create function private.freeze_accepted_document(p_quote uuid) returns void language plpgsql security definer set search_path='' as $$
declare a public.agreements; q public.quotes; j public.jobs; c public.customers; sale uuid; snap jsonb; folio text; y integer; seq bigint; doc uuid; recipient text; company jsonb;
begin
 select * into q from public.quotes where id=p_quote for update;
 if q.unit_id<>'10000000-0000-0000-0000-000000000002' then return; end if;
 if exists(select 1 from public.accepted_documents where quote_id=p_quote) then return; end if;
 select * into a from public.agreements where quote_id=p_quote;
 if a.id is null then raise exception 'Completed acceptance required'; end if;
 select * into j from public.jobs where id=a.job_id;
 select * into c from public.customers where id=a.customer_id;
 select transaction_id into sale from public.sales where job_id=j.id;
 select coalesce(d.recipient,a.commercial_snapshot->>'customer_email') into recipient from private.quote_delivery d where d.quote_id=p_quote;
 recipient:=coalesce(recipient,a.commercial_snapshot->>'customer_email',a.accepted_email);
 company:=coalesce(a.commercial_snapshot->'company',jsonb_build_object('name',c.company_name,'email',c.company_email,'phone',c.company_phone,'address',c.company_address));
 y:=extract(year from a.accepted_at at time zone (select timezone from public.unit_settings where unit_id=q.unit_id));
 insert into private.agreement_sequences(year,value) values(y,1) on conflict(year) do update set value=private.agreement_sequences.value+1 returning value into seq;
 folio:='TT-AGR-'||y||'-'||case when seq<100000 then lpad(seq::text,5,'0') else seq::text end;
 snap:=a.commercial_snapshot||jsonb_build_object(
 'schema_version',1,'acceptance_folio',folio,'customer_name',a.accepted_name,'company',company,
 'customer_email',recipient,'quote_recipient_selection',jsonb_build_object('email',recipient,'kind',case when lower(recipient)=lower(coalesce(company->>'email','')) then 'company' else 'personal' end),
 'accepted_contact_email',a.accepted_email,'customer_phone',a.accepted_phone,
 'quote_id',q.id,'quote_code',q.code,'quote_revision',q.revision,'job_id',j.id,'job_code',j.code,'sale_id',sale,
 'sale_code',(select code from public.sales where transaction_id=sale),
 'quote_accepted_at',q.accepted_at,'agreement_accepted_at',a.accepted_at,
 'agreement',jsonb_build_object('id',a.policy_id,'title',a.commercial_snapshot->'policy'->>'title','version',a.commercial_snapshot->'policy'->'version','text',a.content_snapshot),
 'confirmations',jsonb_build_object('quote',true,'agreement',true),
 'identity',jsonb_build_object('brand','ToolTag','legal','ToolTag is a registered DBA of Bandits of the Framing LLC.'),
 'previous_document_id',(select d.id from public.accepted_documents d join public.quotes oldq on oldq.id=d.quote_id where oldq.flow_id=q.flow_id order by d.accepted_at desc limit 1));
 insert into public.accepted_documents(unit_id,agreement_id,customer_id,quote_id,job_id,sale_id,acceptance_folio,agreement_version,accepted_at,customer_recipient_email,file_name,snapshot,canonical_snapshot,acceptance_snapshot_sha256)
 values(q.unit_id,a.id,a.customer_id,q.id,j.id,sale,folio,(snap->'agreement'->>'version')::integer,a.accepted_at,recipient,folio||'_'||q.code||'_Agreement.pdf',snap,snap::text,encode(sha256(convert_to(snap::text,'UTF8')),'hex')) returning id into doc;
 insert into public.accepted_document_status(document_id,unit_id) values(doc,q.unit_id);
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(q.unit_id,'Accepted Agreement Customer Copy',q.id,'quotes@tooltag.martinlab.studio','accepted-pdf:'||doc||':customer',jsonb_build_object('template','accepted_pdf','document_id',doc,'copy','customer','test',true)),
       (q.unit_id,'Accepted Agreement ToolTag Copy',q.id,'quotes@tooltag.martinlab.studio','accepted-pdf:'||doc||':internal',jsonb_build_object('template','accepted_pdf','document_id',doc,'copy','internal','test',true));
end $$;
revoke all on function private.freeze_accepted_document(uuid) from public,anon,authenticated,service_role;

create function public.claim_accepted_pdf(p_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.accepted_documents; claim uuid;
begin
 if coalesce(auth.role(),'')<>'service_role' then
   if p_id is null then raise exception 'Worker required'; end if;
   perform private.require_admin((select unit_id from public.accepted_documents where id=p_id));
 end if;
 select x.* into d from public.accepted_documents x join public.accepted_document_status s on s.document_id=x.id
 where (p_id is null or x.id=p_id) and s.pdf_status='Pending' order by x.created_at for update of s skip locked limit 1;
 if d.id is null then return null; end if;
 claim:=gen_random_uuid();
 update public.accepted_document_status set pdf_status='Generating',pdf_claim=claim,pdf_started_at=now(),updated_at=now() where document_id=d.id;
 return to_jsonb(d)||jsonb_build_object('claim',claim);
end $$;
create function public.finish_accepted_pdf(p_id uuid,p_claim uuid,p_pdf text default null,p_error text default null) returns boolean language plpgsql security definer set search_path='' as $$
declare s public.accepted_document_status; bytes bytea; hash text;
begin
 select * into s from public.accepted_document_status where document_id=p_id for update;
 perform private.require_admin(s.unit_id);
 if s.pdf_status<>'Generating' or s.pdf_claim is distinct from p_claim then return false; end if;
 if p_pdf is null then
   update public.accepted_document_status set pdf_status='PDF Generation Failed',pdf_error='PDF_GENERATION_FAILED',updated_at=now() where document_id=p_id;
 else
   bytes:=decode(p_pdf,'base64');
   if octet_length(bytes)>4000000 or substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF artifact'; end if;
   hash:=encode(sha256(bytes),'hex');
   insert into private.accepted_pdf_artifacts(document_id,pdf,pdf_sha256) values(p_id,bytes,hash);
   update public.accepted_document_status set pdf_status='Ready',pdf_sha256=hash,pdf_error=null,updated_at=now() where document_id=p_id;
 end if;
 return true;
end $$;
create function public.accepted_pdf_file(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.accepted_documents;
begin
 select * into d from public.accepted_documents where id=p_id;
 if d.id is null then raise exception 'Document not found'; end if;
 if coalesce(auth.role(),'')<>'service_role' and not private.can_access(d.unit_id) then raise exception 'Access denied'; end if;
 return (select jsonb_build_object('file_name',d.file_name,'pdf',encode(a.pdf,'base64'),'sha256',a.pdf_sha256) from private.accepted_pdf_artifacts a where a.document_id=p_id);
end $$;
create function public.claim_accepted_copy(p_id uuid,p_copy text) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.accepted_documents; n public.notifications;
begin
 select * into d from public.accepted_documents where id=p_id;
 perform private.require_admin(d.unit_id);
 if p_copy not in ('customer','internal') then raise exception 'Invalid copy'; end if;
 if not exists(select 1 from private.accepted_pdf_artifacts where document_id=p_id) then return null; end if;
 select * into n from public.notifications where dedupe_key='accepted-pdf:'||p_id||':'||p_copy and status='Pending Integration' for update skip locked;
 if n.id is null then return null; end if;
 update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now() where id=n.id returning * into n;
 return to_jsonb(n);
end $$;
create function public.retry_accepted_document(p_id uuid,p_part text,p_reconciled boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare d public.accepted_documents; s public.accepted_document_status; n public.notifications;
begin
 select * into d from public.accepted_documents where id=p_id;
 perform private.require_admin(d.unit_id);
 if p_part='pdf' then
   select * into s from public.accepted_document_status where document_id=p_id for update;
   if s.pdf_status='Generating' and s.pdf_started_at>now()-interval '10 minutes' then raise exception 'PDF generation is still in progress'; end if;
   if s.pdf_status in ('PDF Generation Failed','Generating') then
     update public.accepted_document_status set pdf_status='Pending',pdf_claim=null,pdf_error=null,updated_at=now() where document_id=p_id;
   end if;
 elsif p_part in ('customer','internal') then
   select * into n from public.notifications where dedupe_key='accepted-pdf:'||p_id||':'||p_part for update;
   if n.status='Queued' and n.mail_attempted_at>now()-interval '10 minutes' then raise exception 'Mail delivery is still in progress'; end if;
   if (n.status='Queued' or n.mail_error='GMAIL_DELIVERY_UNKNOWN') and not p_reconciled then raise exception 'Confirm Gmail Sent mail was reviewed and this copy was not delivered'; end if;
   if n.status in ('Failed','Queued') then
     update public.notifications set status='Pending Integration',mail_claim=null,mail_error=null where id=n.id;
   end if;
 else raise exception 'Invalid retry target'; end if;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value)
 values(d.unit_id,auth.uid(),'accepted_documents',p_id,'retry_requested',jsonb_build_object('part',p_part,'reconciled',p_reconciled));
end $$;
revoke all on function public.claim_accepted_pdf(uuid),public.finish_accepted_pdf(uuid,uuid,text,text),public.accepted_pdf_file(uuid),public.claim_accepted_copy(uuid,text),public.retry_accepted_document(uuid,text,boolean) from public,anon;
grant execute on function public.claim_accepted_pdf(uuid),public.finish_accepted_pdf(uuid,uuid,text,text),public.accepted_pdf_file(uuid),public.claim_accepted_copy(uuid,text),public.retry_accepted_document(uuid,text,boolean) to authenticated,service_role;

create or replace function public.accept_review(p_token text,p_quote_confirmed boolean,p_agreement_confirmed boolean,p_name text,p_email text,p_phone text)
 returns uuid language plpgsql security definer set search_path='' as $$
declare jid uuid; q public.quotes;
begin
 if p_quote_confirmed is distinct from true or p_agreement_confirmed is distinct from true then raise exception 'Both quote and Agreement acknowledgments are required'; end if;
 if nullif(trim(p_name),'') is null or p_email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or nullif(trim(p_email),'') is null or nullif(trim(p_phone),'') is null then raise exception 'Name, valid email and phone are required'; end if;
 select x.* into q from public.quotes x join private.public_links l on l.quote_id=x.id
 where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if q.id is null or q.expires_at<=now() or q.status not in ('Sent','Viewed','Agreement Pending','Accepted') then raise exception 'Quote is unavailable or expired'; end if;
 perform public.accept_quote(p_token);
 jid:=public.accept_agreement(p_token,p_name,p_email,p_phone);
 update public.notifications n set payload=jsonb_build_object('template','confirmation','template_version',1,'snapshot',a.commercial_snapshot,'job_code',j.code,'delivery','Pending Integration')
 from public.agreements a join public.jobs j on j.id=a.job_id
 where n.dedupe_key='agreement:'||q.id and a.quote_id=q.id and n.payload='{}'::jsonb;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
 select q.unit_id,'Drive commercial archive pending',q.id,'drive-commercial:'||q.id,
 jsonb_build_object('job_id',jid,'quote_id',q.id,'agreement_id',a.id,'snapshot_hash',a.snapshot_hash,'folders',jsonb_build_array('Quote','Agreement'))
 from public.agreements a where a.quote_id=q.id on conflict do nothing;
 if q.status<>'Accepted' then perform private.freeze_accepted_document(q.id); end if;
 return jid;
end $$;

create or replace function private.quote_snapshot(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',q.id,'code',q.code,'revision',q.revision,'notes',q.notes,'customer_id',c.id,
 'company',jsonb_build_object('name',c.company_name,'email',c.company_email,'phone',c.company_phone,'address',c.company_address),'customer_name',c.name,'customer_email',c.email,'customer_phone',c.phone,'expires_at',q.expires_at,
 'items',(select jsonb_agg(to_jsonb(i)-'unit_id' order by i.sort_order,i.id) from public.quote_items i where quote_id=q.id),
 'total',(select sum(quantity*unit_price) from public.quote_items where quote_id=q.id),
 'policy',jsonb_build_object('id',p.id,'title',p.title,'version',p.version,'content',p.content))
 from public.quotes q join public.commercial_flows f on f.id=q.flow_id join public.customers c on c.id=f.customer_id
 left join public.policies p on p.id=q.policy_id where q.id=p_id;
$$;

create or replace function private.notification_mail(n public.notifications) returns jsonb language plpgsql security definer set search_path='' as $$
declare q public.quotes; j public.jobs; a public.agreements; t public.transactions; recipient text; token text; title text; body text; receipt jsonb;
begin
 if n.event='Agreement accepted copy' and exists(select 1 from public.accepted_documents where quote_id=n.entity_id) then return null; end if;
 if n.event in ('Quote Sent','Quote expiration reminder','Agreement accepted copy') then
   select * into q from public.quotes where id=n.entity_id and unit_id=n.unit_id;
   if q.id is null or not (n.payload ? 'snapshot') then return null; end if;
   if n.event<>'Agreement accepted copy' and (q.status not in ('Sent','Viewed','Agreement Pending') or q.expires_at<=now()) then return null; end if;
   select d.token into token from private.quote_delivery d where d.quote_id=q.id;
   if token is null then return null; end if;
   return jsonb_build_object('recipient',n.recipient,'token',token,'payload',n.payload);
 elsif n.event in ('Payment receipt','Final Paid receipt') then
   select * into t from public.transactions where id=n.entity_id and unit_id=n.unit_id and status='Active';
   if t.id is null then return null; end if;
   select c.email into recipient from public.customers c where c.id=t.customer_id and c.unit_id=n.unit_id;
   select d.content_snapshot into receipt from public.documents d
     where d.unit_id=n.unit_id and d.type='Payment Receipt' and d.transaction_id=case when n.event='Payment receipt' then n.entity_id else substring(n.dedupe_key from 6)::uuid end
     order by d.created_at desc limit 1;
   if receipt is null then return null; end if;
   title:=case when n.event='Payment receipt' then 'ToolTag payment received' else 'ToolTag paid receipt' end;
   body:='Sale: '||coalesce(receipt->>'sale_code','')||E'\nPayment received: $'||(receipt->>'amount')||E'\nDate: '||(receipt->>'date')||E'\nRemaining balance at payment: $'||coalesce(receipt->>'balance_remaining','0.00');
 elsif n.event in ('Job Ready for Delivery','Completion acknowledgment','Completion reminder','Final completion','Administrative completion','Customer reported issue') then
   select * into j from public.jobs where id=n.entity_id and unit_id=n.unit_id;
   if j.id is null then return null; end if;
   select * into a from public.agreements where job_id=j.id order by accepted_at desc limit 1;
   recipient:=a.accepted_email;
   if n.event='Job Ready for Delivery' and j.status<>'Ready for Delivery' then return null; end if;
   if n.event in ('Completion acknowledgment','Completion reminder') then
     if j.status<>'Delivered – Pending Customer Acceptance' then return null; end if;
     select l.token into token from private.job_mail_links l join private.public_links p on p.token_hash=encode(sha256(convert_to(l.token,'UTF8')),'hex') where l.job_id=j.id and p.expires_at>now();
     if token is null then return null; end if;
   end if;
   if n.event='Final completion' and j.auto_closed_at is not null then return null; end if;
   title:=case n.event when 'Job Ready for Delivery' then 'Your ToolTag job is ready' when 'Customer reported issue' then 'ToolTag received your issue report' when 'Completion acknowledgment' then 'Review your completed ToolTag work' when 'Completion reminder' then 'Reminder: review your ToolTag work' else 'Your ToolTag job is completed' end;
   body:='Job: '||j.code||E'\n'||case n.event when 'Customer reported issue' then 'We received your issue report. Reply to this message to share more details.' when 'Job Ready for Delivery' then 'Your work is ready for delivery.' when 'Completion acknowledgment' then 'Please review your delivered work using the secure link below.' when 'Completion reminder' then 'Please review your delivered work using the secure link below.' else coalesce(j.completion_reason,'Completed') end;
 else
   -- Explicit future template payloads may use the same adapter without inventing event data.
   if n.payload->>'template'='notification' and nullif(n.payload->>'subject','') is not null and nullif(n.payload->>'text','') is not null then
     return jsonb_build_object('recipient',n.recipient,'payload',n.payload);
   end if;
   return null;
 end if;
 return jsonb_build_object('recipient',recipient,'completion_token',token,'payload',jsonb_build_object('template','notification','subject',title,'text',body));
end $$;

create function public.pending_accepted_documents() returns table(document_id uuid) language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker required'; end if;
 return query select s.document_id from public.accepted_document_status s
 where s.pdf_status='Pending' or (s.pdf_status='Ready' and exists(select 1 from public.notifications n where n.payload->>'document_id'=s.document_id::text and n.payload->>'template'='accepted_pdf' and n.status='Pending Integration'))
 order by case when s.pdf_status='Pending' then 0 else 1 end,s.updated_at limit 3;
end $$;
revoke all on function public.pending_accepted_documents() from public,anon,authenticated;
grant execute on function public.pending_accepted_documents() to service_role;
grant select on public.accepted_documents,public.accepted_document_status to service_role;
