-- Delivery destination is separate from immutable customer/commercial snapshots.
alter table private.quote_delivery add column recipient text;
create or replace function private.send_review(p_id uuid,p_regenerate boolean) returns text language plpgsql security definer set search_path='' as $$
declare q public.quotes; policy uuid; token text; snap jsonb; zone text;
begin
 select * into q from public.quotes where id=p_id for update;
 perform private.require_admin(q.unit_id);
 if q.status not in ('Draft','Sent','Viewed') then raise exception 'Create a revision for accepted or expired quotes'; end if;
 if q.expires_at<=now() then raise exception 'Quote expired; create a revision'; end if;
 select id into policy from public.policies where unit_id=q.unit_id and published_at is not null order by version desc limit 1;
 if policy is null then raise exception 'Publish the approved Agreement in Settings before sending a quote'; end if;
 if not exists(select 1 from public.quote_items where quote_id=p_id) or
 (select sum(quantity*unit_price) from public.quote_items where quote_id=p_id)<=0 then raise exception 'Add items with a positive quote total'; end if;
 if not exists(select 1 from public.commercial_flows f join public.customers c on c.id=f.customer_id
 where f.id=q.flow_id and (c.email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or c.company_email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')) then raise exception 'Customer needs a usable email address'; end if;
 select timezone into zone from public.unit_settings where unit_id=q.unit_id;
 update public.quotes set status=case when status='Draft' then 'Sent' else status end,
 policy_id=coalesce(policy_id,policy),sent_at=coalesce(sent_at,now()),
 expires_at=coalesce(expires_at,((now() at time zone zone)+interval '7 days') at time zone zone)
 where id=p_id returning * into q;
 select coalesce(q.review_snapshot,private.quote_snapshot(p_id)) into snap;
 update public.quotes set review_snapshot=snap where id=p_id and review_snapshot is null;
 select d.token into token from private.quote_delivery d where d.quote_id=p_id;
 if token is null or p_regenerate then
 token:=gen_random_uuid()::text||gen_random_uuid()::text;
 if p_regenerate then delete from private.public_links where quote_id=p_id; end if;
 insert into private.public_links values(encode(sha256(convert_to(token,'UTF8')),'hex'),q.unit_id,q.id,null,q.expires_at);
 insert into private.quote_delivery(quote_id,token) values(p_id,token) on conflict(quote_id) do update set token=excluded.token,created_at=now();
 end if;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload)
 values(q.unit_id,'Quote Sent',q.id,'quote:'||q.id,snap->>'customer_email',jsonb_build_object('template','quote','snapshot',snap,'delivery','Pending Integration'))
 on conflict(dedupe_key) do nothing;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,due_at,recipient,payload)
 values(q.unit_id,'Quote expiration reminder',q.id,'quote-reminder:'||q.id,
 ((q.expires_at at time zone zone)-interval '2 days') at time zone zone,snap->>'customer_email',jsonb_build_object('snapshot',snap,'due',false)) on conflict do nothing;
 if p_regenerate then
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value)
 values(q.unit_id,auth.uid(),'quotes',q.id,'link_regenerated',to_jsonb(now()));
 end if;
 return token;
end $$;

create function public.send_quote_to(p_id uuid,p_recipient text,p_regenerate boolean default false)
returns text language plpgsql security definer set search_path='' as $$
declare q public.quotes; c public.customers; destination text:=trim(p_recipient); token text; snap jsonb; prior text;
begin
 select * into q from public.quotes where id=p_id for update;
 perform private.require_admin(q.unit_id);
 select x.* into c from public.customers x join public.commercial_flows f on f.customer_id=x.id where f.id=q.flow_id and x.unit_id=q.unit_id;
 if nullif(destination,'') is null or destination !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or
 not (lower(destination)=lower(coalesce(trim(c.email),'')) or lower(destination)=lower(coalesce(trim(c.company_email),''))) then
   raise exception 'Selecciona el correo personal o de compañía registrado para este cliente';
 end if;
 -- Do not redirect mail that another worker has already claimed.
 perform 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') order by id for update;
 if exists(select 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') and status='Queued') then
   raise exception 'Hay un envío en proceso. Espera antes de cambiar el destinatario';
 end if;
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
revoke all on function public.send_quote_to(uuid,text,boolean) from public,anon;
grant execute on function public.send_quote_to(uuid,text,boolean) to authenticated;

create or replace function public.quote_delivery(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare q public.quotes; token text; a public.agreements; snapshot jsonb;
begin
 select * into q from public.quotes where id=p_id;
 perform private.require_admin(q.unit_id);
 select d.token into token from private.quote_delivery d where d.quote_id=p_id;
 select * into a from public.agreements where quote_id=p_id;
 snapshot:=coalesce(a.commercial_snapshot,q.review_snapshot,private.quote_snapshot(p_id));
 return jsonb_build_object('token',token,'snapshot',snapshot,'accepted',a.id is not null,
 'job_code',(select code from public.jobs where id=a.job_id),'delivery','Pending Integration','recipient',(select d.recipient from private.quote_delivery d where d.quote_id=p_id));
end $$;
