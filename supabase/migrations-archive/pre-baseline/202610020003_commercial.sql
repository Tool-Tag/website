create function public.save_customer(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; cid uuid:=nullif(p->>'id','')::uuid;
begin
 perform private.require_admin(u);
 if exists(select 1 from public.customers where unit_id=u and id is distinct from cid and
 ((nullif(trim(p->>'email'),'') is not null and lower(email)=lower(trim(p->>'email'))) or
 (nullif(regexp_replace(p->>'phone','\D','','g'),'') is not null and regexp_replace(phone,'\D','','g')=regexp_replace(p->>'phone','\D','','g')))) then raise exception 'A customer with this email or phone exists. Open their profile before creating another.'; end if;
 if cid is null then
 insert into public.customers(unit_id,name,phone,email,address,company_name,company_phone,company_email,company_address)
 values(u,trim(p->>'name'),trim(p->>'phone'),lower(trim(p->>'email')),p->>'address',p->>'company_name',p->>'company_phone',p->>'company_email',p->>'company_address') returning id into cid;
 else update public.customers set name=p->>'name',phone=p->>'phone',email=lower(p->>'email'),address=p->>'address',company_name=p->>'company_name',company_phone=p->>'company_phone',company_email=p->>'company_email',company_address=p->>'company_address',updated_at=now() where id=cid and unit_id=u;
 if not found then raise exception 'Customer not found'; end if;
 end if;
 return cid;
end $$;
create function public.create_quote(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
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
 for item in select * from jsonb_array_elements(p->'items') loop
 insert into public.quote_items(unit_id,quote_id,article,quantity,engraving_type,engraving_text,width_mm,height_mm,paint_fill,colors,unit_price,notes,sort_order)
 values(u,qid,item->>'article',(item->>'quantity')::integer,item->>'engraving_type',item->>'engraving_text',nullif(item->>'width_mm','')::numeric,nullif(item->>'height_mm','')::numeric,coalesce((item->>'paint_fill')::boolean,false),coalesce((item->>'colors')::integer,0),(item->>'unit_price')::numeric,item->>'notes',coalesce((item->>'sort_order')::integer,0));
 end loop;
 if (select sum(quantity*unit_price) from public.quote_items where quote_id=qid)<=0 then raise exception 'Quote total must be positive'; end if;
 return qid;
end $$;
create function public.publish_policy(p_unit uuid,p_title text,p_content text) returns uuid language plpgsql security definer set search_path='' as $$
declare pid uuid; v integer;
begin
 perform private.require_admin(p_unit);
 perform 1 from public.business_units where id=p_unit for update;
 select coalesce(max(version),0)+1 into v from public.policies where unit_id=p_unit;
 insert into public.policies(unit_id,version,title,content,published_at) values(p_unit,v,p_title,p_content,now()) returning id into pid;
 return pid;
end $$;
create function public.send_quote(p_id uuid) returns text language plpgsql security definer set search_path='' as $$
declare q public.quotes; policy uuid; token text:=gen_random_uuid()::text||gen_random_uuid()::text;
begin
 select * into q from public.quotes where id=p_id for update;
 perform private.require_admin(q.unit_id);
 if q.status not in ('Draft','Sent','Viewed') then raise exception 'Create a revision for accepted or expired quotes'; end if;
 select id into policy from public.policies where unit_id=q.unit_id and published_at is not null order by version desc limit 1;
 if policy is null then raise exception 'Publish the approved agreement text in Settings before sharing a quote'; end if;
 update public.quotes set status='Sent',policy_id=coalesce(policy_id,policy),sent_at=coalesce(sent_at,now()),expires_at=coalesce(expires_at,now()+interval '7 days') where id=p_id returning * into q;
 if q.expires_at<=now() then raise exception 'Quote expired; create a revision'; end if;
 delete from private.public_links where quote_id=p_id;
 insert into private.public_links values(encode(sha256(convert_to(token,'UTF8')),'hex'),q.unit_id,q.id,null,q.expires_at);
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient) select q.unit_id,'Quote Sent',q.id,'quote:'||q.id,c.email from public.commercial_flows f join public.customers c on c.id=f.customer_id where f.id=q.flow_id on conflict do nothing;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,due_at) values(q.unit_id,'Quote expiration reminder',q.id,'quote-reminder:'||q.id,q.expires_at-interval '2 days') on conflict do nothing;
 return token;
end $$;
create function public.public_quote(p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare l private.public_links; q public.quotes; result jsonb;
begin
 select * into l from private.public_links where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and quote_id is not null and expires_at>now();
 if not found then raise exception 'This link is invalid or expired'; end if;
 select * into q from public.quotes where id=l.quote_id;
 if q.status in ('Declined','Expired','Revised') then raise exception 'Quote is no longer available'; end if;
 update public.quotes set status='Viewed' where id=q.id and status='Sent';
 select jsonb_build_object('id',q.id,'code',q.code,'revision',q.revision,'status',q.status,'expires_at',q.expires_at,'notes',q.notes,
 'customer_name',c.name,'items',(select jsonb_agg(to_jsonb(i)-'unit_id') from public.quote_items i where quote_id=q.id),
 'total',(select sum(quantity*unit_price) from public.quote_items where quote_id=q.id),
 'policy',jsonb_build_object('title',p.title,'version',p.version,'content',p.content),
 'accepted',exists(select 1 from public.agreements where quote_id=q.id)) into result
 from public.commercial_flows f join public.customers c on c.id=f.customer_id join public.policies p on p.id=q.policy_id where f.id=q.flow_id;
 return result;
end $$;
create function public.accept_quote(p_token text) returns void language plpgsql security definer set search_path='' as $$
declare q public.quotes;
begin
 select x.* into q from public.quotes x join private.public_links l on l.quote_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if q.id is null or q.status not in ('Sent','Viewed','Agreement Pending','Accepted') then raise exception 'Quote is not available for acceptance'; end if;
 update public.quotes set status='Agreement Pending',accepted_at=coalesce(accepted_at,now()) where id=q.id and status in ('Sent','Viewed');
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(q.unit_id,'Quote Accepted',q.id,'quote-accepted:'||q.id) on conflict do nothing;
end $$;
create function public.accept_agreement(p_token text,p_name text,p_email text,p_phone text) returns uuid language plpgsql security definer set search_path='' as $$
declare q public.quotes; f public.commercial_flows; jid uuid; sid uuid; total numeric(14,2); items jsonb; pol public.policies;
begin
 select x.* into q from public.quotes x join private.public_links l on l.quote_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if q.id is null then raise exception 'Invalid or expired link'; end if;
 select job_id into jid from public.agreements where quote_id=q.id;
 if jid is not null then return jid; end if; -- retry-safe atomic creation
 if q.status<>'Agreement Pending' then raise exception 'Accept the quote first'; end if;
 if nullif(trim(p_name),'') is null or nullif(trim(p_email),'') is null or nullif(trim(p_phone),'') is null then raise exception 'Your name, email and phone are required'; end if;
 select * into f from public.commercial_flows where id=q.flow_id for update;
 if exists(select 1 from public.quotes where flow_id=f.id and revision>q.revision and status in ('Agreement Pending','Accepted')) then raise exception 'A newer revision has been accepted'; end if;
 select * into pol from public.policies where id=q.policy_id;
 select sum(quantity*unit_price),jsonb_agg(to_jsonb(i)) into total,items from public.quote_items i where quote_id=q.id;
 select id into jid from public.jobs where flow_id=f.id;
 if jid is null then
 insert into public.jobs(unit_id,flow_id,quote_id,code) values(q.unit_id,f.id,q.id,'TT-J-'||f.year||'-'||lpad(f.sequence::text,5,'0')) returning id into jid;
 insert into public.transactions(unit_id,type,transaction_date,amount,customer_id,description,category_id)
 values(q.unit_id,'SALE',(now() at time zone (select timezone from public.unit_settings where unit_id=q.unit_id))::date,total,f.customer_id,'Accepted quote '||q.code,(select id from public.categories where unit_id=q.unit_id and name='Engraving Services')) returning id into sid;
 insert into public.sales(transaction_id,unit_id,job_id,quote_id,code,approved_items,revision) values(sid,q.unit_id,jid,q.id,'TT-S-'||f.year||'-'||lpad(f.sequence::text,5,'0'),items,q.revision);
 else
 select transaction_id into sid from public.sales where job_id=jid for update;
 if (select collected from public.sale_balances where transaction_id=sid)>total then raise exception 'Revision is below collected amount; admin must resolve refund first'; end if;
 -- Preserve original transaction date. Closed period requires an admin-managed correction first.
 update public.transactions set amount=total where id=sid;
 update public.sales set quote_id=q.id,approved_items=items,revision=q.revision where transaction_id=sid;
 update public.jobs set quote_id=q.id where id=jid;
 end if;
 insert into public.sale_versions(unit_id,sale_id,quote_id,revision,amount,approved_items) values(q.unit_id,sid,q.id,q.revision,total,items);
 insert into public.agreements(unit_id,quote_id,policy_id,customer_id,job_id,content_snapshot,accepted_name,accepted_email,accepted_phone)
 values(q.unit_id,q.id,pol.id,f.customer_id,jid,pol.content,trim(p_name),trim(p_email),trim(p_phone));
 update public.quotes set status='Revised' where flow_id=f.id and id<>q.id and status='Accepted';
 update public.quotes set status='Accepted' where id=q.id;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key) values(q.unit_id,'Agreement accepted copy',q.id,p_email,'agreement:'||q.id) on conflict do nothing;
 return jid;
end $$;
create function public.add_document(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; did uuid; tx public.transactions;
begin
 perform private.require_admin(u);
 if nullif(trim(p->>'drive_file_id'),'') is null then raise exception 'A real Google Drive file ID is required; uploads are not connected yet'; end if;
 if p->>'drive_file_id' !~ '^[a-zA-Z0-9_-]{10,}$' then raise exception 'Invalid Drive file ID'; end if;
 insert into public.documents(unit_id,type,drive_file_id,file_name,customer_id,job_id,transaction_id,status,uploaded_by)
 values(u,p->>'type',p->>'drive_file_id',p->>'file_name',nullif(p->>'customer_id','')::uuid,nullif(p->>'job_id','')::uuid,nullif(p->>'transaction_id','')::uuid,'Available',auth.uid()) returning id into did;
 select * into tx from public.transactions where id=nullif(p->>'transaction_id','')::uuid;
 update public.monthly_closes set status=case when status='Reclose Required' then status else 'Documentation Updated' end
 where unit_id=u and month=date_trunc('month',tx.transaction_date)::date and status<>'Superseded';
 return did;
end $$;
create function public.advance_job(p_id uuid,p_action text) returns text language plpgsql security definer set search_path='' as $$
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
 return token; -- no deadline until notification was actually sent/handed to customer
 else raise exception 'Invalid job transition'; end if;
 return null;
end $$;
create function public.confirm_completion_notified(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 select * into j from public.jobs where id=p_id for update; perform private.require_admin(j.unit_id);
 if j.status<>'Delivered – Pending Customer Acceptance' then raise exception 'Deliver first'; end if;
 if j.acceptance_deadline is not null then return; end if;
 update public.jobs set acceptance_deadline=now()+interval '3 days',completion_reason='Completion link manually delivered by admin' where id=p_id;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,due_at) values(j.unit_id,'Completion reminder',j.id,'completion-reminder:'||j.id,now()+interval '2 days') on conflict do nothing;
end $$;
create function public.public_completion(p_token text,p_decision text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 select x.* into j from public.jobs x join private.public_links l on l.job_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() for update of x;
 if j.id is null then raise exception 'Invalid or expired link'; end if;
 if p_decision is not null and j.status<>'Delivered – Pending Customer Acceptance' then raise exception 'This acknowledgment has already been resolved'; end if;
 if p_decision='accept' then update public.jobs set status='Completed',customer_accepted_at=now(),completion_reason='Completed – Customer Accepted' where id=j.id;
 elsif p_decision='issue' then update public.jobs set status='Issue / Review',completion_reason='Customer reported an issue' where id=j.id;
 elsif p_decision is not null then raise exception 'Invalid decision'; end if;
 update public.jobs set completion_link_viewed_at=coalesce(completion_link_viewed_at,now()) where id=j.id returning * into j;
 return jsonb_build_object('code',j.code,'status',j.status,'deadline',j.acceptance_deadline,'reason',j.completion_reason);
end $$;
-- Scheduled worker runs through service_role only; no fake communications or acceptance.
create function public.run_scheduled_tasks() returns void language plpgsql security definer set search_path='' as $$
declare u record; m date;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required'; end if;
 update public.quotes set status='Expired' where status in ('Sent','Viewed','Agreement Pending') and expires_at<now();
 update public.jobs set status='Completed',auto_closed_at=now(),completion_reason='Completed – Deemed Accepted per Agreement'
 where status='Delivered – Pending Customer Acceptance' and acceptance_deadline<now();
 -- Monthly snapshots are created by the same close implementation via an explicit admin worker identity.
 -- See scheduled_close below: no auth impersonation from browser-accessible RPCs.
end $$;
-- Default function EXECUTE privileges are too broad. Explicit API allowlist.
revoke execute on all functions in schema public from public,anon,authenticated;
revoke execute on all functions in schema private from public,anon,authenticated;
grant execute on function private.can_access(uuid) to authenticated;
grant execute on function public.save_customer(jsonb), public.create_quote(jsonb), public.publish_policy(uuid,text,text),public.send_quote(uuid),
 public.record_movement(jsonb),public.create_asset(jsonb),public.close_month(uuid,date),public.update_transaction(jsonb),public.add_document(jsonb),
 public.advance_job(uuid,text),public.confirm_completion_notified(uuid) to authenticated;
grant execute on function public.public_quote(text),public.accept_quote(text),public.accept_agreement(text,text,text,text),public.public_completion(text,text) to anon,authenticated;
grant execute on function public.run_scheduled_tasks() to service_role;
