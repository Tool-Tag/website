-- Additive commercial workflow. No production rows are reset or rewritten.
alter table public.quote_items add column paint_details jsonb not null default '{}'::jsonb;
alter table public.quotes add column review_snapshot jsonb;
alter table public.agreements add column commercial_snapshot jsonb, add column snapshot_hash text,
 add column acceptance_type text not null default 'Quote + Agreement';
-- Recoverable bearer tokens are isolated from every browser role. Existing hashed links remain valid.
create table private.quote_delivery (
 quote_id uuid primary key references public.quotes, token text not null,
 created_at timestamptz not null default now()
);
revoke all on private.quote_delivery from public,anon,authenticated;
create function private.quote_snapshot(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',q.id,'code',q.code,'revision',q.revision,'notes',q.notes,'customer_id',c.id,
 'customer_name',c.name,'customer_email',c.email,'customer_phone',c.phone,'expires_at',q.expires_at,
 'items',(select jsonb_agg(to_jsonb(i)-'unit_id' order by i.sort_order,i.id) from public.quote_items i where quote_id=q.id),
 'total',(select sum(quantity*unit_price) from public.quote_items where quote_id=q.id),
 'policy',jsonb_build_object('id',p.id,'title',p.title,'version',p.version,'content',p.content))
 from public.quotes q join public.commercial_flows f on f.id=q.flow_id join public.customers c on c.id=f.customer_id
 left join public.policies p on p.id=q.policy_id where q.id=p_id;
$$;
create function private.send_review(p_id uuid,p_regenerate boolean) returns text language plpgsql security definer set search_path='' as $$
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
 where f.id=q.flow_id and c.email ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'Customer needs a usable email address'; end if;
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
create or replace function public.send_quote(p_id uuid) returns text language sql security definer set search_path='' as $$
 select private.send_review(p_id,false);
$$;
create function public.regenerate_quote_link(p_id uuid) returns text language sql security definer set search_path='' as $$
 select private.send_review(p_id,true);
$$;
-- Snapshot is captured before INSERT, so immutable acceptance records never need a follow-up UPDATE.
create function private.freeze_acceptance() returns trigger language plpgsql security definer set search_path='' as $$
declare q public.quotes; snap jsonb;
begin
 select * into q from public.quotes where id=NEW.quote_id;
 snap:=coalesce(q.review_snapshot,private.quote_snapshot(q.id));
 NEW.commercial_snapshot:=snap||jsonb_build_object('accepted_at',NEW.accepted_at,'acceptance_type','Quote + Agreement',
 'accepted_name',NEW.accepted_name,'accepted_email',NEW.accepted_email,'accepted_phone',NEW.accepted_phone);
 NEW.snapshot_hash:=encode(sha256(convert_to(NEW.commercial_snapshot::text,'UTF8')),'hex');
 return NEW;
end $$;
create trigger freeze_acceptance before insert on public.agreements for each row execute function private.freeze_acceptance();
create function private.commercial_immutable() returns trigger language plpgsql security definer set search_path='' as $$
begin
 raise exception 'Historical commercial record is immutable; create a revision';
end $$;
create trigger agreement_immutable before update or delete on public.agreements for each row execute function private.commercial_immutable();
create trigger sale_version_immutable before update or delete on public.sale_versions for each row execute function private.commercial_immutable();
create trigger policy_immutable before update or delete on public.policies for each row when (OLD.published_at is not null) execute function private.commercial_immutable();
create function private.protect_quote_scope() returns trigger language plpgsql security definer set search_path='' as $$
declare qid uuid;
begin
 if TG_TABLE_NAME='quotes' then
 if OLD.sent_at is not null and (NEW.flow_id,NEW.revision,NEW.code,NEW.notes,NEW.policy_id,NEW.sent_at,NEW.expires_at) is distinct from
 (OLD.flow_id,OLD.revision,OLD.code,OLD.notes,OLD.policy_id,OLD.sent_at,OLD.expires_at) then raise exception 'Sent quote scope is frozen; create a revision'; end if;
 if OLD.review_snapshot is not null and NEW.review_snapshot is distinct from OLD.review_snapshot then raise exception 'Quote snapshot is immutable'; end if;
 return NEW;
 end if;
 if TG_OP<>'INSERT' then
 if exists(select 1 from public.quotes where id=OLD.quote_id and sent_at is not null) then raise exception 'Sent quote items are immutable'; end if;
 end if;
 if TG_OP<>'DELETE' then
 qid:=NEW.quote_id;
 if exists(select 1 from public.quotes where id=qid and sent_at is not null) then raise exception 'Sent quote items are immutable'; end if;
 return NEW;
 end if;
 return OLD;
end $$;
create trigger quote_scope_guard before update on public.quotes for each row execute function private.protect_quote_scope();
create trigger quote_items_guard before insert or update or delete on public.quote_items for each row execute function private.protect_quote_scope();
create function public.accept_review(p_token text,p_quote_confirmed boolean,p_agreement_confirmed boolean,p_name text,p_email text,p_phone text)
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
 return jid;
end $$;
-- Only the combined endpoint may authorize work from a browser.
revoke execute on function public.accept_quote(text),public.accept_agreement(text,text,text,text) from public,anon,authenticated;
grant execute on function public.accept_review(text,boolean,boolean,text,text,text) to anon,authenticated;
grant execute on function public.regenerate_quote_link(uuid) to authenticated;
create or replace function public.public_quote(p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare l private.public_links; q public.quotes; a public.agreements; snap jsonb; job_code text;
begin
 select * into l from private.public_links where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and quote_id is not null;
 if not found then raise exception 'This link is invalid or expired'; end if;
 select * into q from public.quotes where id=l.quote_id;
 select * into a from public.agreements where quote_id=q.id;
 if a.id is null and (l.expires_at<=now() or q.expires_at<=now() or q.status not in ('Sent','Viewed','Agreement Pending')) then raise exception 'Quote is unavailable or expired'; end if;
 update public.quotes set status='Viewed' where id=q.id and status='Sent';
 select code into job_code from public.jobs where id=a.job_id;
 snap:=coalesce(a.commercial_snapshot,q.review_snapshot,private.quote_snapshot(q.id));
 if a.id is not null then
 if a.commercial_snapshot is null then
 -- Legacy acceptances use their original signer and sale version, never today's Customer profile.
 snap:=snap||jsonb_build_object('customer_name',a.accepted_name,'customer_email',a.accepted_email,'customer_phone',a.accepted_phone,
 'total',(select amount from public.sale_versions where quote_id=q.id limit 1),
 'items',(select approved_items from public.sale_versions where quote_id=q.id limit 1));
 end if;
 snap:=snap||jsonb_build_object('policy',(snap->'policy')||jsonb_build_object('content',a.content_snapshot));
 end if;
 return snap||jsonb_build_object('status',case when q.status='Sent' then 'Viewed' else q.status end,
 'accepted',a.id is not null,'accepted_at',a.accepted_at,'snapshot_hash',a.snapshot_hash,'job_code',job_code);
end $$;
create function public.quote_delivery(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare q public.quotes; token text; a public.agreements; snapshot jsonb;
begin
 select * into q from public.quotes where id=p_id;
 perform private.require_admin(q.unit_id);
 select d.token into token from private.quote_delivery d where d.quote_id=p_id;
 select * into a from public.agreements where quote_id=p_id;
 snapshot:=coalesce(a.commercial_snapshot,q.review_snapshot,private.quote_snapshot(p_id));
 return jsonb_build_object('token',token,'snapshot',snapshot,'accepted',a.id is not null,
 'job_code',(select code from public.jobs where id=a.job_id),'delivery','Pending Integration');
end $$;
grant execute on function public.quote_delivery(uuid) to authenticated;
create or replace function public.create_quote(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; fid uuid; qid uuid; y integer; seq integer; item jsonb; rev integer:=1; oldq public.quotes;
begin
 perform private.require_admin(u);
 if jsonb_array_length(p->'items')=0 or p->'items' is null then raise exception 'Add at least one item'; end if;
 if nullif(p->>'revises_id','') is not null then
 select * into oldq from public.quotes where id=(p->>'revises_id')::uuid and unit_id=u for update;
 if oldq.id is null then raise exception 'Quote not found'; end if;
 fid:=oldq.flow_id;
 perform 1 from public.commercial_flows where id=fid for update;
 select coalesce(max(revision),0)+1 into rev from public.quotes where flow_id=fid;
 select year,sequence into y,seq from public.commercial_flows where id=fid;
 else
 y:=extract(year from now() at time zone (select timezone from public.unit_settings where unit_id=u));
 insert into private.annual_sequences(year,value) values(y,1) on conflict(year) do update set value=private.annual_sequences.value+1 returning value into seq;
 insert into public.commercial_flows(unit_id,customer_id,year,sequence) values(u,(p->>'customer_id')::uuid,y,seq) returning id into fid;
 end if;
 insert into public.quotes(unit_id,flow_id,revision,code,notes) values(u,fid,rev,'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),p->>'notes') returning id into qid;
 for item in select value||jsonb_build_object('sort_order',ordinality-1) from jsonb_array_elements(p->'items') with ordinality loop
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,engraving_text,width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order,marks,paint_details)
 values(u,qid,item->>'article',(item->>'quantity')::integer,item->>'engraving_type',item->>'engraving_text',nullif(item->>'width_mm','')::numeric,nullif(item->>'height_mm','')::numeric,coalesce((item->>'paint_fill')::boolean,false),coalesce((item->>'colors')::integer,0),(item->>'unit_price')::numeric,item->>'notes',coalesce((item->>'sort_order')::integer,0),coalesce(item->'marks','[]'::jsonb),coalesce(item->'paint_details','{}'::jsonb));
 end loop;
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,unit_price,notes,adaptation_fee,sort_order)
 select u,qid,'Adaptación de imagen / logo para Falcon',count(distinct trim(m->>'url'))::integer,'Fee',3.00,'$3 por diseño diferente; se cobra una vez por cotización.',true,1000000
 from jsonb_array_elements(p->'items') i cross join lateral jsonb_array_elements(coalesce(i->'marks','[]'::jsonb)) m
 where i->>'engraving_type'<>'Fee' and m->>'type'='Image / Logo' and nullif(trim(m->>'url'),'') is not null
 having count(distinct trim(m->>'url'))>0;
 if (select sum(quantity*unit_price) from public.quote_items where quote_id=qid)<=0 then raise exception 'Quote total must be positive'; end if;
 return qid;
end $$;
create or replace function public.run_scheduled_tasks() returns void language plpgsql security definer set search_path='' as $$
declare u record; m date; j record;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required'; end if;
 update public.notifications n set payload=n.payload||jsonb_build_object('due',true,'detected_at',now())
 where n.event='Quote expiration reminder' and n.due_at<=now() and coalesce((n.payload->>'due')::boolean,false)=false
 and exists(select 1 from public.quotes q where q.id=n.entity_id and q.status in ('Sent','Viewed','Agreement Pending') and q.expires_at>now());
 update public.quotes set status='Expired'  where status in ('Sent','Viewed','Agreement Pending') and expires_at<now();
 for j in update public.jobs set status='Completed',auto_closed_at=now(),completion_reason='Completed – Deemed Accepted per Agreement'
 where status='Delivered – Pending Customer Acceptance' and acceptance_deadline<now() returning * loop
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(j.unit_id,'Administrative completion',j.id,'auto-complete:'||j.id) on conflict do nothing;
 end loop;
 -- TT only in phase 1. BOFT production and its monthly automation are untouched.
 for u in select s.* from public.unit_settings s join public.business_units b on b.id=s.unit_id where b.code='TOOLTAG' loop
 m:=(date_trunc('month',now() at time zone u.timezone)-interval '1 month')::date;
 if not exists(select 1 from public.monthly_closes where unit_id=u.unit_id and month=m) then perform public.close_month(u.unit_id,m); end if;
 end loop;
end $$;

create or replace function private.queue_commercial_events() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='quotes' then
 if NEW.status='Sent' and NEW.revision>1 and OLD.status<>NEW.status then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(NEW.unit_id,'Revision requires acceptance',NEW.id,'revision:'||NEW.id) on conflict do nothing;
 end if;
 elsif TG_TABLE_NAME='jobs' and NEW.status in ('Completed','Issue / Review') and OLD.status<>NEW.status then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
 values(NEW.unit_id,case when NEW.status='Completed' then 'Final completion' else 'Customer reported issue' end,NEW.id,'job-final:'||NEW.id||':'||NEW.status,jsonb_build_object('reason',NEW.completion_reason)) on conflict do nothing;
 end if;
 return NEW;
end $$;
