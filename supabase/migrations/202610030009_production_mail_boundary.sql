-- Activation is explicit. Installation alone does not enable customer delivery.
create table private.customer_mail_activation(unit_id uuid primary key references public.business_units,enabled_at timestamptz not null);
revoke all on private.customer_mail_activation from public,anon,authenticated,service_role;
alter table public.notifications add column delivery_phase text not null default 'legacy';
alter table public.accepted_document_status add column mail_phase text not null default 'legacy';
create function private.classify_mail() returns trigger language plpgsql security definer set search_path='' as $$
declare started timestamptz; eligible boolean;
begin
 select enabled_at into started from private.customer_mail_activation where unit_id=NEW.unit_id;
 if started is null or coalesce((NEW.payload->>'test')::boolean,false) then NEW.delivery_phase:='test'; return NEW; end if;
 eligible:=coalesce((NEW.payload->>'live_eligible')::boolean,false)
 or exists(select 1 from public.quotes q where q.id=NEW.entity_id and q.sent_at>=started)
 or exists(select 1 from public.jobs j where j.id=NEW.entity_id and (j.created_at>=started or j.completion_email_sent_at>=started))
 or exists(select 1 from public.transactions t where t.id=NEW.entity_id and t.created_at>=started)
 or exists(select 1 from public.transactions t where NEW.event='Final Paid receipt' and t.id::text=split_part(NEW.dedupe_key,':',2) and t.created_at>=started)
 or exists(select 1 from public.job_extensions x where x.id=NEW.entity_id and x.created_at>=started)
 or exists(select 1 from public.job_receipts r where r.id=NEW.entity_id and r.created_at>=started)
 or exists(select 1 from public.accepted_documents d where d.id::text=NEW.payload->>'document_id' and d.created_at>=started);
 NEW.delivery_phase:=case when NEW.created_at>=started and eligible then 'production' else 'legacy' end;
 return NEW;
end $$;
create trigger classify_mail before insert on public.notifications for each row execute function private.classify_mail();
create function public.activate_customer_mail() returns timestamptz language plpgsql security definer set search_path='' as $$
declare u uuid:='10000000-0000-0000-0000-000000000002'; activated timestamptz;
begin
 perform private.require_admin(u);
 insert into private.customer_mail_activation(unit_id,enabled_at) values(u,now()) on conflict do nothing;
 select enabled_at into activated from private.customer_mail_activation where unit_id=u;
 return activated;
end $$;
create function public.customer_mail_status() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.can_access('10000000-0000-0000-0000-000000000002') then raise exception 'Access denied'; end if;
 return jsonb_build_object('activated_at',(select enabled_at from private.customer_mail_activation where unit_id='10000000-0000-0000-0000-000000000002'));
end $$;
revoke all on function public.activate_customer_mail(),public.customer_mail_status() from public,anon;
grant execute on function public.activate_customer_mail(),public.customer_mail_status() to authenticated;
create or replace function public.claim_mail_for_mode(p_quote uuid,p_test_recipient text,p_mode text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.notifications; content jsonb;
begin
 if coalesce(auth.role(),'') <> 'service_role' then
   if p_quote is null then raise exception 'Worker credentials required'; end if;
   perform private.require_admin((select unit_id from public.quotes where id=p_quote));
 end if;
 for n in select x.* from public.notifications x
 where x.unit_id='10000000-0000-0000-0000-000000000002' and (p_quote is null or x.entity_id=p_quote)
 and ((p_mode='live' and x.delivery_phase='production') or (p_mode='test-delivery' and x.delivery_phase='test')) and x.status='Pending Integration' and x.mail_claim is null and x.due_at<=now()
 order by x.created_at for update skip locked loop
   content:=private.notification_mail(n);
   if content is null or nullif(content->>'recipient','') is null then continue; end if;
   if p_test_recipient is not null and lower(content->>'recipient')<>lower(p_test_recipient) then continue; end if;
   update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now(),recipient=content->>'recipient' where id=n.id returning * into n;
   return to_jsonb(n)||content;
 end loop;
 return null;
end $$;
revoke all on function public.claim_mail_for_mode(uuid,text,text) from public,anon;
grant execute on function public.claim_mail_for_mode(uuid,text,text) to authenticated,service_role;
-- Old workers must not bypass the activation boundary.
revoke execute on function public.claim_quote_mail(uuid,text) from authenticated,service_role;
create or replace function private.freeze_accepted_document(p_quote uuid) returns void language plpgsql security definer set search_path='' as $$
declare a public.agreements; q public.quotes; j public.jobs; c public.customers; sale uuid; snap jsonb; folio text; y integer; seq bigint; doc uuid; recipient text; company jsonb; phase text;
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
 company:=coalesce(a.commercial_snapshot->'company','{}'::jsonb);
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
 phase:=case when exists(select 1 from private.customer_mail_activation where unit_id=q.unit_id) then 'production' else 'test' end;
 insert into public.accepted_document_status(document_id,unit_id,mail_phase) values(doc,q.unit_id,phase);
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(q.unit_id,'Accepted Agreement Customer Copy',q.id,case when phase='production' then recipient else 'quotes@tooltag.martinlab.studio' end,'accepted-'||phase||':'||doc||':customer',jsonb_build_object('template','accepted_pdf','document_id',doc,'copy','customer','test',phase='test')),
       (q.unit_id,'Accepted Agreement ToolTag Copy',q.id,'quotes@tooltag.martinlab.studio','accepted-'||phase||':'||doc||':internal',jsonb_build_object('template','accepted_pdf','document_id',doc,'copy','internal','test',phase='test'));
end $$;

create function public.claim_document_copy(p_id uuid,p_copy text,p_mode text) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.accepted_documents; n public.notifications; phase text;
begin
 select * into d from public.accepted_documents where id=p_id; perform private.require_admin(d.unit_id);
 select mail_phase into phase from public.accepted_document_status where document_id=p_id;
 if not ((phase='production' and p_mode='live') or (phase='test' and p_mode='test-delivery')) then return null; end if;
 if p_copy not in ('customer','internal') or not exists(select 1 from private.accepted_pdf_artifacts where document_id=p_id) then return null; end if;
 select * into n from public.notifications where dedupe_key='accepted-'||phase||':'||p_id||':'||p_copy and status='Pending Integration' for update skip locked;
 if n.id is null then return null; end if;
 update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now() where id=n.id returning * into n;
 return to_jsonb(n);
end $$;
revoke all on function public.claim_document_copy(uuid,text,text) from public,anon;
grant execute on function public.claim_document_copy(uuid,text,text) to authenticated,service_role;
revoke execute on function public.claim_accepted_copy(uuid,text) from authenticated,service_role;
create or replace function public.retry_accepted_document(p_id uuid,p_part text,p_reconciled boolean default false) returns void language plpgsql security definer set search_path='' as $$
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
   select * into n from public.notifications where dedupe_key='accepted-'||(select mail_phase from public.accepted_document_status where document_id=p_id)||':'||p_id||':'||p_part for update;
   if n.status='Queued' and n.mail_attempted_at>now()-interval '10 minutes' then raise exception 'Mail delivery is still in progress'; end if;
   if (n.status='Queued' or n.mail_error='GMAIL_DELIVERY_UNKNOWN') and not p_reconciled then raise exception 'Confirm Gmail Sent mail was reviewed and this copy was not delivered'; end if;
   if n.status in ('Failed','Queued') then
     update public.notifications set status='Pending Integration',mail_claim=null,mail_error=null where id=n.id;
   end if;
 else raise exception 'Invalid retry target'; end if;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value)
 values(d.unit_id,auth.uid(),'accepted_documents',p_id,'retry_requested',jsonb_build_object('part',p_part,'reconciled',p_reconciled));
end $$;

create function public.authorize_document_live_copies(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare d public.accepted_documents;
begin
 select * into d from public.accepted_documents where id=p_id; perform private.require_admin(d.unit_id);
 if not exists(select 1 from private.customer_mail_activation where unit_id=d.unit_id) then raise exception 'Activate production mail first'; end if;
 update public.accepted_document_status set mail_phase='production' where document_id=p_id;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(d.unit_id,'Accepted Agreement Customer Copy',d.quote_id,d.customer_recipient_email,'accepted-production:'||d.id||':customer',jsonb_build_object('template','accepted_pdf','document_id',d.id,'copy','customer','test',false,'live_eligible',true)),
 (d.unit_id,'Accepted Agreement ToolTag Copy',d.quote_id,'quotes@tooltag.martinlab.studio','accepted-production:'||d.id||':internal',jsonb_build_object('template','accepted_pdf','document_id',d.id,'copy','internal','test',false,'live_eligible',true)) on conflict do nothing;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values(d.unit_id,auth.uid(),'accepted_documents',d.id,'live_copies_authorized',to_jsonb(now()));
end $$;
revoke all on function public.authorize_document_live_copies(uuid) from public,anon;
grant execute on function public.authorize_document_live_copies(uuid) to authenticated;
create or replace function private.notification_mail_base(n public.notifications) returns jsonb language plpgsql security definer set search_path='' as $$
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


create or replace function private.notification_mail(n public.notifications) returns jsonb language plpgsql security definer set search_path='' as $$
declare l private.job_review_links; x public.job_extensions; token text; j public.jobs;
begin
 if n.payload->>'template'='work_review' then
   select * into l from private.job_review_links where id=(n.payload->>'review_id')::uuid and expires_at>now();
   select * into j from public.jobs where id=l.job_id;
   if l.id is null or l.response_at is not null or j.status<>'Ready for Delivery' or l.id<>(select id from private.job_review_links where job_id=j.id order by created_at desc limit 1) then return null; end if;
   return jsonb_build_object('recipient',n.recipient,'action_path','/work/'||l.token,'payload',jsonb_build_object('template','notification','subject','Your ToolTag work is completed — '||j.code,'text','Your engraving work is completed. Review the approved work and choose Ready for Delivery or request additional work.'));
 elsif n.payload->>'template'='extension_approval' then
   select * into x from public.job_extensions where id=n.entity_id;
   select t.token into token from private.extension_links t where t.extension_id=x.id and t.expires_at>now();
   if x.status<>'Sent' or token is null then return null; end if;
   return jsonb_build_object('recipient',n.recipient,'action_path','/extension/'||token,'payload',jsonb_build_object('template','notification','subject','ToolTag extension approval — '||x.code,'text','Review the additional work and pricing before we proceed. Additional total: $'||x.total));
 elsif n.payload->>'template'='job_receipt' then
   return jsonb_build_object('recipient',n.recipient,'payload',n.payload||(select jsonb_build_object('snapshot',r.snapshot) from public.job_receipts r where r.id=n.entity_id));
 end if;
 return private.notification_mail_base(n);
end $$;
revoke all on function private.notification_mail_base(public.notifications) from public,anon,authenticated,service_role;
create function private.mark_work_notified() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if NEW.status='Sent' and OLD.status<>'Sent' and NEW.payload->>'template'='work_review' then
 update private.job_review_links set notified_at=NEW.sent_at where id=(NEW.payload->>'review_id')::uuid;
 end if; return NEW;
end $$;
create trigger work_notified after update on public.notifications for each row execute function private.mark_work_notified();
create or replace function public.send_quote_to(p_id uuid,p_recipient text,p_regenerate boolean default false)
returns text language plpgsql security definer set search_path='' as $$
declare q public.quotes; c public.customers; destination text:=trim(p_recipient); token text; snap jsonb; prior text;
begin
 select * into q from public.quotes where id=p_id for update;
 perform private.require_admin(q.unit_id);
 select x.* into c from public.customers x join public.commercial_flows f on f.customer_id=x.id where f.id=q.flow_id and x.unit_id=q.unit_id;
 select d.recipient into prior from private.quote_delivery d where d.quote_id=p_id;
 if nullif(destination,'') is null or destination !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or
 not (lower(destination)=lower(coalesce(prior,'')) or lower(destination)=lower(coalesce(trim(c.email),'')) or lower(destination)=lower(coalesce(trim(c.company_email),''))) then
   raise exception 'Selecciona el correo personal o de compañía registrado para este cliente';
 end if;
 -- Do not redirect mail that another worker has already claimed.
 perform 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') order by id for update;
 if exists(select 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') and status='Queued') then
   raise exception 'Hay un envío en proceso. Espera antes de cambiar el destinatario';
 end if;
 select d.recipient into prior from private.quote_delivery d where d.quote_id=p_id;
 if prior is not null and lower(prior)<>lower(destination) then raise exception 'El destinatario de esta versión está fijado. Crea una revisión para cambiarlo'; end if;
 token:=private.send_review(p_id,p_regenerate);
 select recipient into prior from private.quote_delivery where quote_id=p_id;
 update private.quote_delivery set recipient=destination where quote_id=p_id;
 update public.notifications set recipient=destination where entity_id=p_id and event in ('Quote Sent','Quote expiration reminder') and status='Pending Integration';
 select review_snapshot into snap from public.quotes where id=p_id;
 -- A different destination after delivery needs its own delivery record.
 if exists(select 1 from public.notifications where entity_id=p_id and event='Quote Sent' and status='Sent') and
 not exists(select 1 from public.notifications where entity_id=p_id and event='Quote Sent' and lower(recipient)=lower(destination) and status in ('Sent','Queued','Pending Integration')) then
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload)
   values(q.unit_id,'Quote Sent',q.id,'quote:'||q.id||':recipient:'||encode(sha256(convert_to(lower(destination),'UTF8')),'hex'),destination,jsonb_build_object('template','quote','snapshot',snap)) on conflict do nothing;
 end if;
 if prior is distinct from destination then
   insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,old_value,new_value)
   values(q.unit_id,auth.uid(),'quotes',q.id,'mail_recipient',to_jsonb(prior),to_jsonb(destination));
 end if;
 return token;
end $$;

create or replace function public.pending_accepted_documents() returns table(document_id uuid) language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker required'; end if;
 return query select s.document_id from public.accepted_document_status s
 where s.pdf_status='Pending' or (s.pdf_status='Ready' and s.mail_phase in ('production','test') and exists(select 1 from public.notifications n where n.payload->>'document_id'=s.document_id::text and n.payload->>'template'='accepted_pdf' and n.delivery_phase=s.mail_phase and n.status='Pending Integration'))
 order by case when s.pdf_status='Pending' then 0 else 1 end,s.updated_at limit 3;
end $$;
-- Reconcile only an explicitly chosen failure; no bulk backlog replay.
create function public.retry_customer_notification(p_id uuid,p_reconciled boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare n public.notifications;
begin
 select * into n from public.notifications where id=p_id for update; perform private.require_admin(n.unit_id);
 if n.payload->>'template'='accepted_pdf' then raise exception 'Use the accepted document controls'; end if;
 if n.status='Sent' then raise exception 'This message has already been sent'; end if;
 if n.status='Queued' and n.mail_attempted_at>now()-interval '10 minutes' then raise exception 'Delivery still in progress'; end if;
 if not p_reconciled then raise exception 'Confirm that this specific message should be sent and was not already delivered'; end if;
 if not exists(select 1 from private.customer_mail_activation where unit_id=n.unit_id) then raise exception 'Activate production mail first'; end if;
 update public.notifications set delivery_phase='production',status='Pending Integration',mail_claim=null,mail_error=null where id=p_id;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values(n.unit_id,auth.uid(),'notifications',n.id,'manual_retry_authorized',to_jsonb(now()));
end $$;
revoke all on function public.retry_customer_notification(uuid,boolean) from public,anon;
grant execute on function public.retry_customer_notification(uuid,boolean) to authenticated;

-- Repair missing document metadata from immutable acceptance data only.
create function public.prepare_existing_accepted_document(p_quote uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.agreements; d uuid;
begin
 select * into a from public.agreements where quote_id=p_quote;
 perform private.require_admin(a.unit_id);
 if a.id is null or a.commercial_snapshot is null or a.commercial_snapshot->'items' is null then raise exception 'No complete immutable acceptance snapshot; manual review required'; end if;
 perform 1 from public.quotes where id=p_quote for update;
 select id into d from public.accepted_documents where quote_id=p_quote;
 if d is not null then return d; end if;
 perform private.freeze_accepted_document(p_quote);
 select id into d from public.accepted_documents where quote_id=p_quote;
 -- Recovery creates no new acceptance and does not authorize any historical email.
 update public.accepted_document_status set mail_phase='legacy' where document_id=d;
 update public.notifications set delivery_phase='legacy' where payload->>'document_id'=d::text;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values(a.unit_id,auth.uid(),'accepted_documents',d,'recovered_from_acceptance',to_jsonb(a.id));
 return d;
end $$;
revoke all on function public.prepare_existing_accepted_document(uuid) from public,anon;
grant execute on function public.prepare_existing_accepted_document(uuid) to authenticated;
