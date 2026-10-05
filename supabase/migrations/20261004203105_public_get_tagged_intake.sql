-- Public intake ends at Draft. All privileged entry points are explicitly scoped.
alter table public.quotes add column source text not null default 'internal',
 add column intake_details jsonb, add column intake_reviewed_at timestamptz;
create index quotes_intake_review_idx on public.quotes(unit_id,created_at) where source='public_get_tagged' and status='Draft' and intake_reviewed_at is null;
create table private.get_tagged_receipts (
 id uuid primary key, fingerprint text not null, details jsonb not null,
 reference text not null unique default ('TT-R-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
 quote_id uuid unique references public.quotes(id), customer_id uuid references public.customers(id),
 matching text not null check(matching in ('created','reused','review')),
 candidates uuid[] not null default '{}',created_at timestamptz not null default now()
);
create table private.get_tagged_rate (
 network text not null, bucket timestamptz not null, requests integer not null,
 primary key(network,bucket)
);
alter table private.get_tagged_receipts enable row level security;
alter table private.get_tagged_rate enable row level security;
revoke all on private.get_tagged_receipts,private.get_tagged_rate from public,anon,authenticated;

create function private.get_tagged_phone(p text) returns text language sql immutable set search_path='' as $$
 select case when length(n)=11 and left(n,1)='1' then substr(n,2) else n end from (select regexp_replace(coalesce(p,''),'[^0-9]','','g') n)s;
$$;
-- Same approved pricing engine. Description-only logos are deliberately unpriced
-- for adaptation until an admin supplies their reference. Engraving/paint still count.
create function private.get_tagged_scope(p_items jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare i jsonb; m jsonb; normalized jsonb:='[]'; marks jsonb; result jsonb:='[]'; priced jsonb; pos integer:=0;
begin
 for i in select value from jsonb_array_elements(p_items) loop
  marks:='[]';
  for m in select value from jsonb_array_elements(i->'marks') loop
   if m->>'type'='Image / Logo' and coalesce(m->>'url','')='' then
    m:=m||jsonb_build_object('type','Text','text',m->>'description');
   end if;
   marks:=marks||jsonb_build_array(m);
  end loop;
  normalized:=normalized||jsonb_build_array(i||jsonb_build_object('marks',marks,'unit_price',0));
 end loop;
 priced:=private.priced_scope(normalized);
 for i in select value from jsonb_array_elements(priced) loop
  if i->>'engraving_type'<>'Fee' then
   i:=i||jsonb_build_object('marks',p_items->pos->'marks','engraving_type',p_items->pos->>'engraving_type');pos:=pos+1;
  elsif coalesce((i->>'additional_engraving_fee')::boolean,false) then
   i:=i||jsonb_build_object('article','Additional engravings','notes','First engraving included; $5 for each additional engraving per piece.');
  elsif coalesce((i->>'paint_fee')::boolean,false) then
   i:=i||jsonb_build_object('article','Paint fill','notes','$2 per painted physical piece, separate from additional engravings.');
  elsif coalesce((i->>'adaptation_fee')::boolean,false) then
   i:=i||jsonb_build_object('article','Falcon image / logo preparation','notes','$3 per distinct referenced design.');
  end if;
  result:=result||jsonb_build_array(i);
 end loop;return result;
end $$;

create function private.store_get_tagged_items(p_quote uuid,p_scope jsonb) returns void language plpgsql security definer set search_path='' as $$
declare i jsonb;
begin
 for i in select value from jsonb_array_elements(p_scope) loop
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,engraving_text,width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order,marks,paint_details,adaptation_fee,paint_fee,additional_engraving_fee,pricing)
 values('10000000-0000-0000-0000-000000000002',p_quote,i->>'article',(i->>'quantity')::integer,i->>'engraving_type',i->>'engraving_text',nullif(i->>'width_mm','')::numeric,nullif(i->>'height_mm','')::numeric,false,0,(i->>'unit_price')::numeric,i->>'notes',(i->>'sort_order')::integer,coalesce(i->'marks','[]'),coalesce(i->'paint_details','{}'),coalesce((i->>'adaptation_fee')::boolean,false),coalesce((i->>'paint_fee')::boolean,false),coalesce((i->>'additional_engraving_fee')::boolean,false),coalesce(i->'pricing','{}'));
 end loop;
end $$;
create function private.create_get_tagged_draft(p_receipt uuid,p_customer uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare u constant uuid:='10000000-0000-0000-0000-000000000002'; y integer; seq integer; fid uuid; qid uuid; r private.get_tagged_receipts;
begin
 select * into r from private.get_tagged_receipts where id=p_receipt for update;
 if r.quote_id is not null then return r.quote_id; end if;
 if not exists(select 1 from public.customers where id=p_customer and unit_id=u) then raise exception 'Customer not found'; end if;
 y:=extract(year from now() at time zone (select timezone from public.unit_settings where unit_id=u));
 insert into private.annual_sequences(year,value) values(y,1) on conflict(year) do update set value=private.annual_sequences.value+1 returning value into seq;
 insert into public.commercial_flows(unit_id,customer_id,year,sequence) values(u,p_customer,y,seq) returning id into fid;
 insert into public.quotes(unit_id,flow_id,code,notes,source,intake_details)
 values(u,fid,'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),r.details->>'notes','public_get_tagged',r.details-'quote_items') returning id into qid;
 perform private.store_get_tagged_items(qid,private.get_tagged_scope(r.details->'quote_items'));
 update private.get_tagged_receipts set quote_id=qid,customer_id=p_customer where id=p_receipt;
 return qid;
end $$;

create function public.submit_get_tagged(p_key uuid,p_network text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u constant uuid:='10000000-0000-0000-0000-000000000002'; r private.get_tagged_receipts; fingerprint text; candidates uuid[]; cid uuid; count_requests integer; rate_bucket timestamptz:=date_trunc('hour',now())+floor(extract(minute from now())/15)*interval '15 minutes'; contact jsonb:=p_payload->'contact'; qid uuid;
begin
 -- This function is reachable only by the server-side service role, never browsers.
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Server credentials required' using errcode='42501'; end if;
 if p_payload is null or p_network is null or p_key is null or p_network !~ '^[a-f0-9]{64}$' or length(p_payload::text)>100000
 or nullif(trim(contact->>'name'),'') is null or coalesce(contact->>'email','') !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
 or length(private.get_tagged_phone(contact->>'phone')) not between 7 and 15
 or jsonb_typeof(p_payload->'quote_items') is distinct from 'array' or jsonb_array_length(p_payload->'quote_items') not between 1 and 20 then raise exception 'Invalid request'; end if;
 perform pg_advisory_xact_lock(hashtextextended('tooltag-get-tagged',0));
 fingerprint:=encode(sha256(convert_to(p_payload::text,'UTF8')),'hex');
 select * into r from private.get_tagged_receipts where id=p_key;
 if found then
  if r.fingerprint<>fingerprint then raise exception 'Request already submitted'; end if;
  return jsonb_build_object('reference',r.reference);
 end if;
 insert into private.get_tagged_rate values(p_network,rate_bucket,1) on conflict(network,bucket) do update set requests=private.get_tagged_rate.requests+1 returning requests into count_requests;
 if count_requests>5 then raise exception 'Request rate limit'; end if;
 insert into private.get_tagged_rate values('global',rate_bucket,1) on conflict(network,bucket) do update set requests=private.get_tagged_rate.requests+1 returning requests into count_requests;
 if count_requests>100 then raise exception 'Request rate limit'; end if;
 delete from private.get_tagged_rate where bucket<now()-interval '2 days';
 -- Also serializes matching against the existing admin customer insert/update path.
 lock table public.customers in share row exclusive mode;
 select coalesce(array_agg(c.id),'{}') into candidates from public.customers c where c.unit_id=u and
 (lower(trim(c.email))=lower(trim(contact->>'email')) or private.get_tagged_phone(c.phone)=private.get_tagged_phone(contact->>'phone'));
 if cardinality(candidates)>1 then
  insert into private.get_tagged_receipts(id,fingerprint,details,matching,candidates) values(p_key,fingerprint,p_payload,'review',candidates) returning * into r;
 else
  if cardinality(candidates)=1 then cid:=candidates[1];
  else
   insert into public.customers(unit_id,name,email,phone,address,company_name,company_email,company_phone)
   values(u,trim(contact->>'name'),lower(trim(contact->>'email')),trim(contact->>'phone'),coalesce(p_payload->'service'->>'address',''),nullif(contact->>'company_name',''),nullif(contact->>'company_email',''),nullif(contact->>'company_phone','')) returning id into cid;
  end if;
  insert into private.get_tagged_receipts(id,fingerprint,details,matching,candidates) values(p_key,fingerprint,p_payload,case when cardinality(candidates)=1 then 'reused' else 'created' end,candidates) returning * into r;
  qid:=private.create_get_tagged_draft(p_key,cid);
 end if;
 return jsonb_build_object('reference',r.reference);
end $$;
revoke all on function public.submit_get_tagged(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.submit_get_tagged(uuid,text,jsonb) to service_role;

create function public.get_tagged_attention() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');
 return (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'reference',r.reference,'name',r.details->'contact'->>'name','created_at',r.created_at,'quote_id',r.quote_id,'matching',r.matching,'candidates',(select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'email',c.email,'phone',c.phone)) from public.customers c where c.id=any(r.candidates)))),'[]') from private.get_tagged_receipts r left join public.quotes q on q.id=r.quote_id where r.quote_id is null or (q.status='Draft' and q.intake_reviewed_at is null));
end $$;
create function public.resolve_get_tagged(p_id uuid,p_customer uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare r private.get_tagged_receipts; qid uuid;
begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');
 select * into r from private.get_tagged_receipts where id=p_id for update;
 if r.id is null or not(p_customer=any(r.candidates)) then raise exception 'Select one of the matching customers'; end if;
 qid:=private.create_get_tagged_draft(p_id,p_customer);
 update private.get_tagged_receipts set matching='reused' where id=p_id;
 return qid;
end $$;
create function public.review_get_tagged_quote(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare q public.quotes; scope jsonb; i jsonb;
begin
 select * into q from public.quotes where id=(p->>'id')::uuid for update;
 perform private.require_admin(q.unit_id);
 if q.source<>'public_get_tagged' or q.status<>'Draft' or q.sent_at is not null then raise exception 'This request is no longer an editable Draft'; end if;
 scope:=private.priced_scope(p->'items');
 for i in select value from jsonb_array_elements(scope) loop
  if i->>'engraving_type'<>'Fee' and (i->>'unit_price')::numeric<=0 then raise exception 'Set the base service price for each item before completing review'; end if;
 end loop;
 delete from public.quote_items where quote_id=q.id;
 perform private.store_get_tagged_items(q.id,scope);
 update public.quotes set notes=p->>'notes',intake_reviewed_at=now() where id=q.id;
 return q.id;
end $$;
create function private.guard_get_tagged_review() returns trigger language plpgsql set search_path='' as $$
begin
 if old.source='public_get_tagged' and old.intake_reviewed_at is null and new.status not in ('Draft','Declined','Expired') then raise exception 'Review and price this Get Tagged request before sending'; end if;
 return new;
end $$;
create trigger get_tagged_review_guard before update on public.quotes for each row execute function private.guard_get_tagged_review();
revoke all on function public.get_tagged_attention(),public.resolve_get_tagged(uuid,uuid),public.review_get_tagged_quote(jsonb) from public,anon;
grant execute on function public.get_tagged_attention(),public.resolve_get_tagged(uuid,uuid),public.review_get_tagged_quote(jsonb) to authenticated;
revoke all on function private.get_tagged_phone(text),private.get_tagged_scope(jsonb),private.store_get_tagged_items(uuid,jsonb),private.create_get_tagged_draft(uuid,uuid),private.guard_get_tagged_review() from public,anon,authenticated;
notify pgrst,'reload schema';
