alter table public.unit_settings add column if not exists zelle_email text, add column if not exists venmo_handle text;

create table if not exists public.payment_requests (
 id uuid primary key default gen_random_uuid(),
 request_key uuid not null unique,
 unit_id uuid not null references public.business_units,
 job_id uuid not null references public.jobs,
 method text not null check(method in ('Cash','Zelle','Venmo')),
 amount numeric(14,2) not null check(amount>0),
 status text not null default 'Pending Verification' check(status in ('Pending Verification','Confirmed','Rejected','Cancelled')),
 proof_path text,
 submitted_at timestamptz not null default now(),
 confirmed_at timestamptz,
 confirmed_by uuid references auth.users,
 confirmed_amount numeric(14,2),
 transaction_ids uuid[] not null default '{}'
);
create unique index if not exists payment_requests_one_pending on public.payment_requests(job_id) where status='Pending Verification';
alter table public.payment_requests enable row level security;
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='payment_requests' and policyname='payment_requests_read') then
  create policy payment_requests_read on public.payment_requests for select to authenticated using(private.can_access(unit_id));
 end if;
end $$;
revoke all on public.payment_requests from public,anon,authenticated;
grant select on public.payment_requests to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('payment-proofs','payment-proofs',false,5242880,array['image/png','image/jpeg','image/webp'])
on conflict(id) do nothing;
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='payment_proofs_admin_read') then
  create policy payment_proofs_admin_read on storage.objects for select to authenticated using(
   bucket_id='payment-proofs'
   and (storage.foldername(name))[1]='10000000-0000-0000-0000-000000000002'
   and exists(select 1 from public.memberships where user_id=auth.uid() and unit_id='10000000-0000-0000-0000-000000000002' and role='admin')
  );
 end if;
end $$;

create or replace function private.job_payment_snapshot(p_job uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'grand_total',coalesce(t.grand_total,0),
  'collected',coalesce(t.collected,0),
  'balance_due',coalesce(t.balance_due,0),
  'paid_in_full',coalesce(t.balance_due,0)=0,
  'request',(select jsonb_build_object('id',r.id,'method',r.method,'amount',r.amount,'status',r.status,'submitted_at',r.submitted_at,'confirmed_at',r.confirmed_at,'confirmed_amount',r.confirmed_amount) from public.payment_requests r where r.job_id=p_job order by r.submitted_at desc limit 1),
  'methods',jsonb_build_object('cash',true,'zelle_email',(select zelle_email from public.unit_settings where unit_id=j.unit_id),'venmo_handle',(select venmo_handle from public.unit_settings where unit_id=j.unit_id))
 )
 from public.jobs j
 left join public.job_commercial_totals t on t.id=j.id
 where j.id=p_job;
$$;
revoke all on function private.job_payment_snapshot(uuid) from public,anon,authenticated,service_role;

create or replace function public.public_submit_payment_request(p_token text,p_request uuid,p_method text,p_proof_path text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; due numeric(14,2); existing public.payment_requests; rid uuid; zelle text; venmo text;
begin
 select x.* into j from public.jobs x join private.public_links l on l.job_id=x.id
 where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if j.id is null then raise exception 'Invalid or expired link'; end if;
 if not exists(select 1 from public.delivery_acknowledgments where job_id=j.id) then raise exception 'Confirm delivery before choosing payment'; end if;
 select * into existing from public.payment_requests where request_key=p_request;
 if existing.id is not null then return jsonb_build_object('id',existing.id,'status',existing.status,'method',existing.method,'amount',existing.amount); end if;
 if exists(select 1 from public.payment_requests where job_id=j.id and status='Pending Verification') then raise exception 'A payment is already awaiting verification'; end if;
 select balance_due into due from public.job_commercial_totals where id=j.id;
 if coalesce(due,0)<=0 then raise exception 'This job is already paid in full'; end if;
 if p_method not in ('Cash','Zelle','Venmo') then raise exception 'Choose Cash, Zelle or Venmo'; end if;
 select zelle_email,venmo_handle into zelle,venmo from public.unit_settings where unit_id=j.unit_id;
 if p_method='Zelle' and nullif(trim(zelle),'') is null then raise exception 'Zelle is not configured yet'; end if;
 if p_method='Venmo' and nullif(trim(venmo),'') is null then raise exception 'Venmo is not configured yet'; end if;
 if p_method in ('Zelle','Venmo') and nullif(trim(p_proof_path),'') is null then raise exception 'Upload payment proof for Zelle or Venmo'; end if;
 insert into public.payment_requests(request_key,unit_id,job_id,method,amount,proof_path)
 values(p_request,j.unit_id,j.id,p_method,due,p_proof_path) returning id into rid;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(j.unit_id,'PAYMENT_SUBMITTED',rid,'billing@tooltag.martinlab.studio','payment-request:'||rid,
 jsonb_build_object('template','notification','subject','Payment verification needed — '||j.code,'text','A customer submitted a '||p_method||' payment request for $'||due||'. Verify it in ToolTag before recording payment.','live_eligible',true))
 on conflict do nothing;
 return jsonb_build_object('id',rid,'status','Pending Verification','method',p_method,'amount',due);
end $$;
revoke all on function public.public_submit_payment_request(text,uuid,text,text) from public;
grant execute on function public.public_submit_payment_request(text,uuid,text,text) to anon,authenticated;

create or replace function public.confirm_payment_request(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.payment_requests; j public.jobs; remaining numeric(14,2); due numeric(14,2); alloc numeric(14,2); paid numeric(14,2):=0; rec record; tid uuid; tids uuid[]:='{}';
begin
 select * into r from public.payment_requests where id=p_id for update;
 if r.id is null then raise exception 'Payment request not found'; end if;
 perform private.require_admin(r.unit_id);
 if r.status='Confirmed' then return jsonb_build_object('id',r.id,'status',r.status,'confirmed_amount',r.confirmed_amount,'transaction_ids',r.transaction_ids); end if;
 if r.status<>'Pending Verification' then raise exception 'Payment request is not pending verification'; end if;
 select * into j from public.jobs where id=r.job_id for update;
 select balance_due into due from public.job_commercial_totals where id=j.id;
 if coalesce(due,0)<=0 then raise exception 'This job is already paid in full'; end if;
 remaining:=least(r.amount,due);
 for rec in
  select * from (
   select 0 as sort_order,s.transaction_id,s.balance_due,s.customer_id from public.sale_balances s where s.job_id=j.id and s.transaction_status<>'Voided' and s.balance_due>0
   union all
   select x.sequence,s.transaction_id,s.balance_due,s.customer_id from public.job_extensions x join public.sale_balances s on s.transaction_id=x.sale_id where x.job_id=j.id and x.status in ('Approved','Completed') and s.transaction_status<>'Voided' and s.balance_due>0
  ) q order by sort_order,transaction_id
 loop
  exit when remaining<=0;
  alloc:=least(remaining,rec.balance_due);
  insert into public.transactions(unit_id,type,transaction_date,amount,customer_id,description,payment_method,reference,created_by)
  values(r.unit_id,'COLLECTION',(now() at time zone (select timezone from public.unit_settings where unit_id=r.unit_id))::date,alloc,rec.customer_id,'Verified customer payment · '||j.code,r.method,'PAYREQ:'||r.id,auth.uid()) returning id into tid;
  insert into public.collections(transaction_id,unit_id,sale_id) values(tid,r.unit_id,rec.transaction_id);
  tids:=array_append(tids,tid); paid:=paid+alloc; remaining:=remaining-alloc;
 end loop;
 if paid<=0 then raise exception 'No outstanding sale balance was available'; end if;
 update public.payment_requests set status='Confirmed',confirmed_at=now(),confirmed_by=auth.uid(),confirmed_amount=paid,transaction_ids=tids where id=r.id returning * into r;
 perform public.generate_job_receipt(j.id);
 return jsonb_build_object('id',r.id,'status',r.status,'confirmed_amount',r.confirmed_amount,'transaction_ids',r.transaction_ids);
end $$;
revoke all on function public.confirm_payment_request(uuid) from public,anon;
grant execute on function public.confirm_payment_request(uuid) to authenticated;

create or replace function private.receipt_after_collection() returns trigger language plpgsql security definer set search_path='' as $$
declare jid uuid; ref text;
begin
 select reference into ref from public.transactions where id=NEW.transaction_id;
 if ref like 'PAYREQ:%' then return NEW; end if;
 select coalesce(s.job_id,x.job_id) into jid from public.sales s left join public.job_extensions x on x.sale_id=s.transaction_id where s.transaction_id=NEW.sale_id;
 if exists(select 1 from public.jobs where id=jid and unit_id='10000000-0000-0000-0000-000000000002' and status in ('Delivered – Pending Customer Acceptance','Completed','Issue / Review')) then perform public.generate_job_receipt(jid); end if;
 return NEW;
end $$;

create or replace function public.public_completion(p_token text,p_decision text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; scope jsonb; customer uuid; snap jsonb;
begin
 select x.* into j from public.jobs x join private.public_links l on l.job_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if j.id is null then raise exception 'Invalid or expired link'; end if;
 select snapshot into scope from private.delivery_scopes where job_id=j.id;
 scope:=coalesce(scope,private.job_portal_snapshot(j.id));
 if p_decision is not null then
  if p_decision='accept' and exists(select 1 from public.delivery_acknowledgments where job_id=j.id) then
   return scope||jsonb_build_object('status',j.status,'reason',j.completion_reason)||jsonb_build_object('payment',private.job_payment_snapshot(j.id));
  end if;
  if j.status<>'Delivered – Pending Customer Acceptance' then raise exception 'This delivery acknowledgment has already been resolved'; end if;
  if p_decision='accept' then
   select customer_id into customer from public.commercial_flows where id=j.flow_id;
   snap:=jsonb_build_object('job_id',j.id,'job_code',j.code,'customer_id',customer,'scope',scope,'delivered_at',j.delivered_at,'acknowledged_at',now(),'confirmation','I confirm that I received the items/work associated with this ToolTag Job.','method','Secure link / electronic confirmation');
   insert into public.delivery_acknowledgments(unit_id,job_id,customer_id,delivered_at,snapshot,snapshot_sha256)
   values(j.unit_id,j.id,customer,j.delivered_at,snap,encode(sha256(convert_to(snap::text,'UTF8')),'hex')) on conflict(job_id) do nothing;
   update public.jobs set status='Completed',customer_accepted_at=now(),completion_reason='Completed – Customer Accepted' where id=j.id;
  elsif p_decision='issue' then
   update public.jobs set status='Issue / Review',completion_reason='Customer reported an issue' where id=j.id;
  else raise exception 'Invalid decision'; end if;
 end if;
 update public.jobs set completion_link_viewed_at=coalesce(completion_link_viewed_at,now()) where id=j.id returning * into j;
 return scope||jsonb_build_object('status',j.status,'reason',j.completion_reason,'acknowledgment',(select jsonb_build_object('id',a.id,'acknowledged_at',a.acknowledged_at) from public.delivery_acknowledgments a where a.job_id=j.id),'payment',private.job_payment_snapshot(j.id));
end $$;
