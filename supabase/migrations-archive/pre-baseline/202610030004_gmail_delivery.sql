-- Claim once before contacting Gmail. An interrupted send remains queued for manual
-- reconciliation; never automatically resend an outcome that may have been delivered.
alter table public.notifications add column mail_claim uuid,
 add column provider_id text, add column mail_error text, add column mail_attempted_at timestamptz;
create table private.job_mail_links(job_id uuid primary key references public.jobs, token text not null);
revoke all on private.job_mail_links from public,anon,authenticated;
-- Resolve only supported customer events. Internal accounting/Drive events stay untouched.
create function private.notification_mail(n public.notifications) returns jsonb language plpgsql security definer set search_path='' as $$
declare q public.quotes; j public.jobs; a public.agreements; t public.transactions; recipient text; token text; title text; body text; receipt jsonb;
begin
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
revoke all on function private.notification_mail(public.notifications) from public,anon,authenticated;
create function public.claim_quote_mail(p_quote uuid default null, p_test_recipient text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.notifications; content jsonb;
begin
 if coalesce(auth.role(),'') <> 'service_role' then
   if p_quote is null then raise exception 'Worker credentials required'; end if;
   perform private.require_admin((select unit_id from public.quotes where id=p_quote));
 end if;
 for n in select x.* from public.notifications x
 where x.unit_id='10000000-0000-0000-0000-000000000002' and (p_quote is null or x.entity_id=p_quote)
 and x.status='Pending Integration' and x.mail_claim is null and x.due_at<=now()
 order by x.created_at for update skip locked loop
   content:=private.notification_mail(n);
   if content is null or nullif(content->>'recipient','') is null then continue; end if;
   if p_test_recipient is not null and lower(content->>'recipient')<>lower(p_test_recipient) then continue; end if;
   update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now(),recipient=content->>'recipient' where id=n.id returning * into n;
   return to_jsonb(n)||content;
 end loop;
 return null;
end $$;
create function public.finish_quote_mail(p_id uuid,p_claim uuid,p_provider_id text default null,p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare n public.notifications;
begin
 select * into n from public.notifications where id=p_id for update;
 perform private.require_admin(n.unit_id);
 if n.mail_claim is distinct from p_claim or n.status<>'Queued' then return false; end if;
 if nullif(p_provider_id,'') is null and p_error is null then raise exception 'Delivery result required'; end if;
 update public.notifications set status=case when nullif(p_provider_id,'') is not null then 'Sent' else 'Failed' end,
 provider_id=p_provider_id,mail_error=p_error,sent_at=case when nullif(p_provider_id,'') is not null then now() else null end
 where id=p_id;
 if nullif(p_provider_id,'') is not null and n.event='Completion acknowledgment' then
   update public.jobs set completion_email_sent_at=now(),acceptance_deadline=coalesce(acceptance_deadline,now()+interval '3 days')
   where id=n.entity_id and status='Delivered – Pending Customer Acceptance';
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,due_at)
   values(n.unit_id,'Completion reminder',n.entity_id,'completion-reminder:'||n.entity_id,now()+interval '2 days') on conflict do nothing;
 end if;
 return true;
end $$;
revoke all on function public.claim_quote_mail(uuid,text),public.finish_quote_mail(uuid,uuid,text,text) from public,anon;
grant execute on function public.claim_quote_mail(uuid,text),public.finish_quote_mail(uuid,uuid,text,text) to authenticated,service_role;

create or replace function public.advance_job(p_id uuid,p_action text) returns text language plpgsql security definer set search_path='' as $$
declare j public.jobs; token text:=gen_random_uuid()::text||gen_random_uuid()::text;
begin
 select * into j from public.jobs where id=p_id for update; perform private.require_admin(j.unit_id);
 if p_action='start' and j.status in ('Authorized','Receiving Documentation') then
 if not exists(select 1 from public.documents where job_id=j.id and type='Receiving Evidence' and status='Available') then raise exception 'Add receiving evidence first'; end if;
 update public.jobs set status='In Process',updated_at=now() where id=j.id;
 elsif p_action='ready' and j.status='In Process' then
 if not exists(select 1 from public.documents where job_id=j.id and type='Completed Evidence' and status='Available') then raise exception 'Add completed evidence first'; end if;
 update public.jobs set status='Ready for Delivery',updated_at=now() where id=j.id;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(j.unit_id,'Job Ready for Delivery',j.id,'ready:'||j.id) on conflict do nothing;
 elsif p_action='deliver' and j.status='Ready for Delivery' then
 update public.jobs set status='Delivered – Pending Customer Acceptance',delivered_at=now(),updated_at=now() where id=j.id;
 insert into private.public_links values(encode(sha256(convert_to(token,'UTF8')),'hex'),j.unit_id,null,j.id,now()+interval '30 days');
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(j.unit_id,'Completion acknowledgment',j.id,'delivery:'||j.id) on conflict do nothing;
 insert into private.job_mail_links(job_id,token) values(j.id,token) on conflict(job_id) do update set token=excluded.token;
 return token; -- no deadline until notification was actually sent/handed to customer
 else raise exception 'Invalid job transition'; end if;
 return null;
end $$;
