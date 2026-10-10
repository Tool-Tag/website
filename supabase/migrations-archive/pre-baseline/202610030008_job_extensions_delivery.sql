-- Additive job components. Original quotes/agreements/transactions remain unchanged.
create table public.job_extensions (
 id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units,
 job_id uuid not null references public.jobs, sequence integer not null, code text not null unique,
 request_key uuid not null unique default gen_random_uuid(), requested_at timestamptz not null default now(),
 customer_request text not null, scope text not null default '', items jsonb not null default '[]',
 total numeric(14,2) not null default 0, status text not null default 'Requested' check(status in ('Requested','Draft','Sent','Approved','Completed','Cancelled')),
 accepted_at timestamptz, accepted_snapshot jsonb, snapshot_sha256 text, sale_id uuid unique references public.sales(transaction_id),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(job_id,sequence)
);
create table private.job_review_links (
 id uuid primary key default gen_random_uuid(), job_id uuid not null references public.jobs,
 token text not null, token_hash text not null unique, created_at timestamptz not null default now(), expires_at timestamptz not null,
 notified_at timestamptz, viewed_at timestamptz, response_at timestamptz, response text, customer_request text
);
create table private.extension_links(extension_id uuid primary key references public.job_extensions,token text not null,token_hash text not null unique,expires_at timestamptz not null);
create table public.delivery_acknowledgments (
 id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units, job_id uuid not null unique references public.jobs,
 customer_id uuid not null references public.customers, delivered_at timestamptz not null, acknowledged_at timestamptz not null default now(),
 acceptance_method text not null default 'Secure link / electronic confirmation', snapshot jsonb not null, snapshot_sha256 text not null
);
create table public.job_receipts (
 id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units, job_id uuid not null references public.jobs,
 snapshot jsonb not null, snapshot_sha256 text not null, created_at timestamptz not null default now(), storage_status text not null default 'Pending Drive Upload',
 unique(job_id,snapshot_sha256)
);
revoke all on private.job_review_links,private.extension_links from public,anon,authenticated,service_role;
do $$ declare t text; begin
 foreach t in array array['job_extensions','delivery_acknowledgments','job_receipts'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select on public.%I to authenticated,service_role',t);
 execute format('create policy tenant_read on public.%I for select to authenticated using(private.can_access(unit_id))',t);
 execute format('create trigger audit_record after insert or update on public.%I for each row execute function private.audit_change()',t);
 end loop;
end $$;
create trigger delivery_ack_immutable before update or delete on public.delivery_acknowledgments for each row execute function private.commercial_immutable();
create trigger receipt_immutable before update or delete on public.job_receipts for each row execute function private.commercial_immutable();
create function private.protect_extension() returns trigger language plpgsql set search_path='' as $$
begin
 if TG_OP='DELETE' then raise exception 'Extension history cannot be deleted'; end if;
 if (NEW.id,NEW.job_id,NEW.unit_id,NEW.sequence,NEW.code,NEW.request_key,NEW.requested_at,NEW.customer_request) is distinct from (OLD.id,OLD.job_id,OLD.unit_id,OLD.sequence,OLD.code,OLD.request_key,OLD.requested_at,OLD.customer_request) then raise exception 'Extension identity is immutable'; end if;
 if OLD.status in ('Sent','Approved','Completed') and (NEW.scope,NEW.items,NEW.total) is distinct from (OLD.scope,OLD.items,OLD.total) then raise exception 'Sent extension scope is immutable; cancel an unaccepted proposal and create another extension'; end if;
 if OLD.accepted_at is not null and (NEW.accepted_at,NEW.accepted_snapshot,NEW.snapshot_sha256,NEW.sale_id) is distinct from (OLD.accepted_at,OLD.accepted_snapshot,OLD.snapshot_sha256,OLD.sale_id) then raise exception 'Accepted extension is immutable'; end if;
 if OLD.accepted_at is not null and NEW.status not in ('Approved','Completed') then raise exception 'Accepted extension cannot be cancelled'; end if;
 NEW.updated_at:=now(); return NEW;
end $$;
create trigger protect_extension before update or delete on public.job_extensions for each row execute function private.protect_extension();
create view public.job_commercial_totals with(security_invoker=true) as
 select j.id,j.unit_id,
 coalesce(b.amount,0) as base_amount,coalesce(e.amount,0) as extensions_amount,coalesce(b.amount,0)+coalesce(e.amount,0) as grand_total,
 coalesce(b.collected,0)+coalesce(e.collected,0) as collected,coalesce(b.refunded,0)+coalesce(e.refunded,0) as refunded,
 greatest(0,coalesce(b.amount,0)+coalesce(e.amount,0)-coalesce(b.collected,0)-coalesce(e.collected,0)) as balance_due
 from public.jobs j
 left join public.sale_balances b on b.job_id=j.id and b.transaction_status<>'Voided'
 left join lateral (select sum(s.amount) amount,sum(s.collected) collected,sum(s.refunded) refunded from public.job_extensions x join public.sale_balances s on s.transaction_id=x.sale_id where x.job_id=j.id and x.status in ('Approved','Completed') and s.transaction_status<>'Voided') e on true;
grant select on public.job_commercial_totals to authenticated,service_role;

create function private.job_portal_snapshot(p_job uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',j.id,'code',j.code,'status',j.status,'customer_name',a.accepted_name,
 'original_quote',a.commercial_snapshot,'extensions',coalesce((select jsonb_agg(jsonb_build_object('code',x.code,'scope',x.scope,'items',x.items,'total',x.total,'status',x.status) order by x.sequence) from public.job_extensions x where x.job_id=j.id and x.accepted_at is not null),'[]'::jsonb),
 'totals',(select to_jsonb(t) from public.job_commercial_totals t where t.id=j.id),
 'evidence',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.file_name,'type',d.type)) from public.documents d where d.job_id=j.id and d.type='Completed Evidence' and d.status='Available'),'[]'::jsonb))
 from public.jobs j join public.agreements a on a.quote_id=j.quote_id where j.id=p_job;
$$;
revoke all on function private.job_portal_snapshot(uuid) from public,anon,authenticated,service_role;
create function public.job_lifecycle(p_job uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 select * into j from public.jobs where id=p_job;
 if not private.can_access(j.unit_id) then raise exception 'Access denied'; end if;
 return jsonb_build_object('customer',(select jsonb_build_object('name',a.accepted_name,'email',coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email')) from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id),'review',(select to_jsonb(l)-'token'-'token_hash' from private.job_review_links l where l.job_id=p_job order by l.created_at desc limit 1),'review_path',(select '/work/'||l.token from private.job_review_links l where l.job_id=p_job order by l.created_at desc limit 1));
end $$;
create function public.request_job_extension(p_job uuid,p_request text,p_key uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare j public.jobs; seq integer; eid uuid;
begin
 select * into j from public.jobs where id=p_job for update; perform private.require_admin(j.unit_id);
 if j.status not in ('Authorized','Receiving Documentation','In Process','Ready for Delivery') then raise exception 'Job is not active'; end if;
 if nullif(trim(p_request),'') is null then raise exception 'Describe the requested work'; end if;
 select id into eid from public.job_extensions where request_key=p_key and job_id=p_job; if eid is not null then return eid; end if;
 select coalesce(max(sequence),0)+1 into seq from public.job_extensions where job_id=p_job;
 insert into public.job_extensions(unit_id,job_id,sequence,code,customer_request,request_key) values(j.unit_id,j.id,seq,j.code||'/X'||seq,trim(p_request),p_key) returning id into eid;
 return eid;
end $$;
create function public.public_work_review(p_token text,p_response text default null,p_request text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare l private.job_review_links; j public.jobs; seq integer;
begin
 select * into l from private.job_review_links where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and expires_at>now();
 if l.id is null then raise exception 'Link unavailable'; end if;
 select * into j from public.jobs where id=l.job_id for update;
 select * into l from private.job_review_links where id=l.id for update;
 if l.id<>(select id from private.job_review_links where job_id=j.id order by created_at desc limit 1) then raise exception 'A newer review is available'; end if;
 update private.job_review_links set viewed_at=coalesce(viewed_at,now()) where id=l.id;
 if p_response is not null and l.response_at is null then
   if j.status<>'Ready for Delivery' then raise exception 'Job is not ready for review'; end if;
   if p_response not in ('ready','additional') then raise exception 'Invalid response'; end if;
   if p_response='additional' then
     if nullif(trim(p_request),'') is null or length(p_request)>5000 then raise exception 'Describe your additional request'; end if;
     select coalesce(max(sequence),0)+1 into seq from public.job_extensions where job_id=j.id;
     insert into public.job_extensions(unit_id,job_id,sequence,code,customer_request,request_key) values(j.unit_id,j.id,seq,j.code||'/X'||seq,trim(p_request),l.id) on conflict(request_key) do nothing;
   end if;
   update private.job_review_links set response=p_response,response_at=now(),customer_request=case when p_response='additional' then trim(p_request) end where id=l.id returning * into l;
 end if;
 return private.job_portal_snapshot(j.id)||jsonb_build_object('response',l.response,'response_at',l.response_at);
end $$;
create function public.save_job_extension(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare x public.job_extensions; priced jsonb; total numeric;
begin
 select * into x from public.job_extensions where id=(p->>'id')::uuid for update;
 perform private.require_admin(x.unit_id);
 if x.status not in ('Requested','Draft') then raise exception 'Only a draft extension can be edited'; end if;
 priced:=private.priced_scope(p->'items');
 select sum((i->>'quantity')::numeric*(i->>'unit_price')::numeric) into total from jsonb_array_elements(priced) i;
 if total<=0 then raise exception 'Extension total must be positive'; end if;
 update public.job_extensions set scope=coalesce(p->>'notes',''),items=priced,total=total,status='Draft' where id=x.id;
 return x.id;
end $$;
create function public.send_job_extension(p_id uuid) returns text language plpgsql security definer set search_path='' as $$
declare x public.job_extensions; j public.jobs; token text; recipient text;
begin
 select * into x from public.job_extensions where id=p_id; select * into j from public.jobs where id=x.job_id for update;
 select * into x from public.job_extensions where id=p_id for update; perform private.require_admin(x.unit_id);
 if x.status not in ('Draft','Sent') or x.total<=0 then raise exception 'Prepare the extension scope first'; end if;
 if j.status not in ('In Process','Ready for Delivery','Authorized','Receiving Documentation') then raise exception 'Job is not active'; end if;
 select l.token into token from private.extension_links l where l.extension_id=x.id;
 if token is null then
   token:=gen_random_uuid()::text||gen_random_uuid()::text;
   insert into private.extension_links values(x.id,token,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '7 days');
 end if;
 select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email') into recipient from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id;
 update public.job_extensions set status='Sent' where id=x.id;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload) values(x.unit_id,'QUOTE_REVISION',x.id,'extension:'||x.id,recipient,jsonb_build_object('template','extension_approval','extension_id',x.id)) on conflict do nothing;
 return token;
end $$;
create function public.cancel_job_extension(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare x public.job_extensions; j public.jobs; token text; review_id uuid; recipient text;
begin
 select * into x from public.job_extensions where id=p_id;
 select * into j from public.jobs where id=x.job_id for update;
 select * into x from public.job_extensions where id=p_id for update; perform private.require_admin(x.unit_id);
 if x.accepted_at is not null then raise exception 'Accepted extensions cannot be cancelled'; end if;
 if x.status='Cancelled' then return; end if;
 update public.job_extensions set status='Cancelled' where id=p_id;
 if j.status='Ready for Delivery' and not exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent','Approved')) then
   token:=gen_random_uuid()::text||gen_random_uuid()::text;
   insert into private.job_review_links(job_id,token,token_hash,expires_at) values(j.id,token,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '30 days') returning id into review_id;
   select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email') into recipient from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id;
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload) values(j.unit_id,'JOB_READY',j.id,'job-ready:'||review_id,recipient,jsonb_build_object('template','work_review','review_id',review_id,'live_eligible',true));
 end if;
end $$;
create function public.public_extension(p_token text,p_accept boolean default false,p_name text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare x public.job_extensions; j public.jobs; sid uuid; snap jsonb; customer uuid; current_total numeric;
begin
 select e.* into x from public.job_extensions e join private.extension_links l on l.extension_id=e.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and (l.expires_at>now() or e.accepted_at is not null);
 if x.id is null or x.status='Cancelled' then raise exception 'Extension link unavailable'; end if;
 select * into j from public.jobs where id=x.job_id for update;
 select * into x from public.job_extensions where id=x.id for update;
 if p_accept and x.accepted_at is null then
   if x.status<>'Sent' or j.status not in ('In Process','Ready for Delivery','Authorized','Receiving Documentation') or nullif(trim(p_name),'') is null then raise exception 'Extension is not available for acceptance'; end if;
   select grand_total into current_total from public.job_commercial_totals where id=j.id;
   select customer_id into customer from public.commercial_flows where id=j.flow_id;
   insert into public.transactions(unit_id,type,transaction_date,amount,customer_id,description,category_id)
   values(j.unit_id,'SALE',(now() at time zone (select timezone from public.unit_settings where unit_id=j.unit_id))::date,x.total,customer,'Approved job extension '||x.code,(select id from public.categories where unit_id=j.unit_id and name='Engraving Services')) returning id into sid;
   insert into public.sales(transaction_id,unit_id,code,approved_items) values(sid,j.unit_id,replace(x.code,'TT-J-','TT-S-'),x.items);
   snap:=jsonb_build_object('extension_id',x.id,'code',x.code,'job_id',j.id,'job_code',j.code,'scope',x.scope,'items',x.items,'total',x.total,'accepted_name',trim(p_name),'accepted_at',now(),'original_agreement_id',(select id from public.agreements where quote_id=j.quote_id),'job_total_after',current_total+x.total,'approved',true);
   update public.job_extensions set status='Approved',sale_id=sid,accepted_at=now(),accepted_snapshot=snap,snapshot_sha256=encode(sha256(convert_to(snap::text,'UTF8')),'hex') where id=x.id returning * into x;
   update public.jobs set status='In Process' where id=j.id;
 end if;
 select grand_total into current_total from public.job_commercial_totals where id=j.id;
 return jsonb_build_object('code',x.code,'job_code',j.code,'scope',x.scope,'items',x.items,'total',x.total,'status',x.status,'accepted_at',x.accepted_at,'grand_total',current_total+case when x.accepted_at is null then x.total else 0 end);
end $$;
revoke all on function public.job_lifecycle(uuid),public.request_job_extension(uuid,text,uuid),public.save_job_extension(jsonb),public.send_job_extension(uuid),public.cancel_job_extension(uuid) from public,anon;
grant execute on function public.job_lifecycle(uuid),public.request_job_extension(uuid,text,uuid),public.save_job_extension(jsonb),public.send_job_extension(uuid),public.cancel_job_extension(uuid) to authenticated;
revoke all on function public.public_work_review(text,text,text),public.public_extension(text,boolean,text) from public;
grant execute on function public.public_work_review(text,text,text),public.public_extension(text,boolean,text) to anon,authenticated;

create table private.delivery_scopes(job_id uuid primary key references public.jobs,snapshot jsonb not null);
revoke all on private.delivery_scopes from public,anon,authenticated,service_role;
create function public.generate_job_receipt(p_job uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare j public.jobs; snap jsonb; rid uuid; fingerprint text; recipient text;
begin
 select * into j from public.jobs where id=p_job for update; perform private.require_admin(j.unit_id);
 snap:=private.job_portal_snapshot(j.id)-'evidence'-'status';
 snap:=snap||jsonb_build_object('payments',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'date',t.transaction_date,'amount',t.amount,'method',t.payment_method,'reference',t.reference) order by t.transaction_date,t.created_at) from public.collections c join public.transactions t on t.id=c.transaction_id where t.status<>'Voided' and c.sale_id in (select transaction_id from public.sales where job_id=j.id union select sale_id from public.job_extensions where job_id=j.id and accepted_at is not null)),'[]'::jsonb),
 'paid_in_full',coalesce((snap->'totals'->>'balance_due')::numeric=0 and (snap->'totals'->>'refunded')::numeric=0,false),
 'paid_in_full_date',case when (snap->'totals'->>'balance_due')::numeric=0 and (snap->'totals'->>'refunded')::numeric=0 then (select max(t.transaction_date) from public.collections c join public.transactions t on t.id=c.transaction_id where t.status<>'Voided' and c.sale_id in (select transaction_id from public.sales where job_id=j.id union select sale_id from public.job_extensions where job_id=j.id and accepted_at is not null)) end);
 fingerprint:=encode(sha256(convert_to(snap::text,'UTF8')),'hex');
 insert into public.job_receipts(unit_id,job_id,snapshot,snapshot_sha256) values(j.unit_id,j.id,snap,fingerprint) on conflict(job_id,snapshot_sha256) do nothing returning id into rid;
 if rid is null then select id into rid from public.job_receipts where job_id=j.id and snapshot_sha256=fingerprint; return rid; end if;
 select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email') into recipient from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload) values(j.unit_id,'FINAL_PAID_RECEIPT',rid,recipient,'job-receipt:'||rid,jsonb_build_object('template','job_receipt','receipt_id',rid));
 return rid;
end $$;
revoke all on function public.generate_job_receipt(uuid) from public,anon;
grant execute on function public.generate_job_receipt(uuid) to authenticated,service_role;

create or replace function public.advance_job(p_id uuid,p_action text) returns text language plpgsql security definer set search_path='' as $$
declare j public.jobs; token text:=gen_random_uuid()::text||gen_random_uuid()::text; review_id uuid; recipient text;
begin
 select * into j from public.jobs where id=p_id for update; perform private.require_admin(j.unit_id);
 if p_action='start' and j.status in ('Authorized','Receiving Documentation') then
   if not exists(select 1 from public.documents where job_id=j.id and type='Receiving Evidence' and status='Available') then raise exception 'Add receiving evidence first'; end if;
   update public.jobs set status='In Process',updated_at=now() where id=j.id;
 elsif p_action='ready' and j.status='In Process' then
   if exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent')) then raise exception 'Resolve pending extensions first'; end if;
   if not exists(select 1 from public.documents where job_id=j.id and type='Completed Evidence' and status='Available' and created_at>=coalesce((select max(accepted_at) from public.job_extensions where job_id=j.id),j.created_at)) then raise exception 'Add current completed evidence first'; end if;
   update public.job_extensions set status='Completed' where job_id=j.id and status='Approved';
   update public.jobs set status='Ready for Delivery',updated_at=now() where id=j.id;
   insert into private.job_review_links(job_id,token,token_hash,expires_at) values(j.id,token,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '30 days') returning id into review_id;
   select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email') into recipient from public.agreements a left join public.accepted_documents d on d.agreement_id=a.id where a.quote_id=j.quote_id;
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload) values(j.unit_id,'JOB_READY',j.id,'job-ready:'||review_id,recipient,jsonb_build_object('template','work_review','review_id',review_id,'live_eligible',true));
 elsif p_action='deliver' and j.status='Ready for Delivery' then
   if exists(select 1 from public.job_extensions where job_id=j.id and status not in ('Completed','Cancelled')) then raise exception 'Complete or resolve extensions before delivery'; end if;
   if exists(select 1 from private.job_review_links where job_id=j.id) and coalesce((select response from private.job_review_links where job_id=j.id order by created_at desc limit 1),'')<>'ready' then raise exception 'Wait for the customer Ready for Delivery response'; end if;
   insert into private.delivery_scopes(job_id,snapshot) values(j.id,private.job_portal_snapshot(j.id)) on conflict do nothing;
   update public.jobs set status='Delivered – Pending Customer Acceptance',delivered_at=now(),updated_at=now() where id=j.id;
   insert into private.public_links(token_hash,unit_id,job_id,expires_at) values(encode(sha256(convert_to(token,'UTF8')),'hex'),j.unit_id,j.id,now()+interval '30 days');
   insert into private.job_mail_links(job_id,token) values(j.id,token) on conflict(job_id) do update set token=excluded.token;
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values(j.unit_id,'Completion acknowledgment',j.id,'delivery:'||j.id,jsonb_build_object('live_eligible',true)) on conflict do nothing;
   perform public.generate_job_receipt(j.id);
   return token;
 else raise exception 'Invalid job transition'; end if;
 return null;
end $$;
create or replace function public.public_completion(p_token text,p_decision text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; scope jsonb; customer uuid; snap jsonb;
begin
 select x.* into j from public.jobs x join private.public_links l on l.job_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if j.id is null then raise exception 'Invalid or expired link'; end if;
 select snapshot into scope from private.delivery_scopes where job_id=j.id;
 scope:=coalesce(scope,private.job_portal_snapshot(j.id));
 if p_decision is not null then
   if p_decision='accept' and exists(select 1 from public.delivery_acknowledgments where job_id=j.id) then return scope||jsonb_build_object('status',j.status,'reason',j.completion_reason); end if;
   if j.status<>'Delivered – Pending Customer Acceptance' then raise exception 'This delivery acknowledgment has already been resolved'; end if;
   if p_decision='accept' then
     select customer_id into customer from public.commercial_flows where id=j.flow_id;
     snap:=jsonb_build_object('job_id',j.id,'job_code',j.code,'customer_id',customer,'scope',scope,'delivered_at',j.delivered_at,'acknowledged_at',now(),'confirmation','I confirm that I received the items/work associated with this ToolTag Job.','method','Secure link / electronic confirmation');
     insert into public.delivery_acknowledgments(unit_id,job_id,customer_id,delivered_at,snapshot,snapshot_sha256) values(j.unit_id,j.id,customer,j.delivered_at,snap,encode(sha256(convert_to(snap::text,'UTF8')),'hex')) on conflict(job_id) do nothing;
     update public.jobs set status='Completed',customer_accepted_at=now(),completion_reason='Completed – Customer Accepted' where id=j.id;
   elsif p_decision='issue' then update public.jobs set status='Issue / Review',completion_reason='Customer reported an issue' where id=j.id;
   else raise exception 'Invalid decision'; end if;
 end if;
 update public.jobs set completion_link_viewed_at=coalesce(completion_link_viewed_at,now()) where id=j.id returning * into j;
 return scope||jsonb_build_object('status',j.status,'reason',j.completion_reason,'acknowledgment',(select jsonb_build_object('id',a.id,'acknowledged_at',a.acknowledged_at) from public.delivery_acknowledgments a where a.job_id=j.id));
end $$;

create trigger delivery_scope_immutable before update or delete on private.delivery_scopes for each row execute function private.commercial_immutable();
-- A payment received after physical delivery refreshes the consolidated summary.
create function private.receipt_after_collection() returns trigger language plpgsql security definer set search_path='' as $$
declare jid uuid;
begin
 select coalesce(s.job_id,x.job_id) into jid from public.sales s left join public.job_extensions x on x.sale_id=s.transaction_id where s.transaction_id=NEW.sale_id;
 if exists(select 1 from public.jobs where id=jid and unit_id='10000000-0000-0000-0000-000000000002' and status in ('Delivered – Pending Customer Acceptance','Completed','Issue / Review')) then perform public.generate_job_receipt(jid); end if;
 return NEW;
end $$;
create trigger receipt_after_collection after insert on public.collections for each row execute function private.receipt_after_collection();
revoke all on function private.receipt_after_collection() from public,anon,authenticated,service_role;
