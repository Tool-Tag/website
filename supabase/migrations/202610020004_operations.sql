create function public.save_settings(p jsonb) returns void language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid;
begin
 perform private.require_admin(u);
 if p ? 'timezone' and not exists(select 1 from pg_timezone_names where name=p->>'timezone') then raise exception 'Invalid timezone'; end if;
 if p ? 'boft_url' and p->>'boft_url' !~ '^https://' then raise exception 'BOFT URL must use HTTPS'; end if;
 update public.unit_settings set timezone=coalesce(p->>'timezone',timezone),drive_root_id=coalesce(p->>'drive_root_id',drive_root_id),boft_url=coalesce(p->>'boft_url',boft_url),annual_vehicle_method=coalesce(p->>'annual_vehicle_method',annual_vehicle_method),mileage_rate=coalesce((p->>'mileage_rate')::numeric,mileage_rate) where unit_id=u;
end $$;
create function public.record_mileage(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; mid uuid;
begin
 perform private.require_admin(u);
 insert into public.mileage(unit_id,date,purpose,origin,destination,miles,notes) values(u,(p->>'date')::date,p->>'purpose',p->>'origin',p->>'destination',(p->>'miles')::numeric,p->>'notes') returning id into mid;
 return mid;
end $$;
create function public.save_category(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; cid uuid;
begin
 perform private.require_admin(u);
 if nullif(p->>'id','') is not null then
 update public.categories set active=coalesce((p->>'active')::boolean,active) where id=(p->>'id')::uuid and unit_id=u returning id into cid;
 else insert into public.categories(unit_id,name,kind) values(u,p->>'name',p->>'kind') returning id into cid;
 end if;
 return cid;
end $$;
create function public.search_records(p_unit uuid,p_query text) returns table(id uuid,kind text,label text,path text) language plpgsql stable security definer set search_path='' as $$
begin
 if not private.can_access(p_unit) then raise exception 'Access denied'; end if;
 if length(trim(p_query))<2 then return; end if;
 return query
 select q.id,'Quote',q.code||' v'||q.revision,'/app/quotes/'||q.id from public.quotes q where q.unit_id=p_unit and q.code ilike '%'||p_query||'%'
 union all select j.id,'Job',j.code,'/app/jobs/'||j.id from public.jobs j where j.unit_id=p_unit and j.code ilike '%'||p_query||'%'
 union all select s.transaction_id,'Sale',s.code,'/app/finance/sales/'||s.transaction_id from public.sales s where s.unit_id=p_unit and s.code ilike '%'||p_query||'%'
 union all select d.id,'Document',d.file_name,case when d.job_id is not null then '/app/jobs/'||d.job_id when d.transaction_id is not null then '/app/finance/transactions/'||d.transaction_id when d.customer_id is not null then '/app/customers/'||d.customer_id else '/app/finance/review' end from public.documents d where d.unit_id=p_unit and (d.file_name ilike '%'||p_query||'%' or d.type ilike '%'||p_query||'%') limit 100;
end $$;
create function public.vehicle_report(p_unit uuid,p_year integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare method text; rate numeric; miles numeric; fuel numeric;
begin
 if not private.can_access(p_unit) then raise exception 'Access denied'; end if;
 select annual_vehicle_method,mileage_rate into method,rate from public.unit_settings where unit_id=p_unit;
 select coalesce(sum(m.miles),0) into miles from public.mileage m where unit_id=p_unit and extract(year from date)=p_year;
 select coalesce(sum(t.amount),0) into fuel from public.transactions t join public.categories c on c.id=t.category_id where t.unit_id=p_unit and t.type='EXPENSE' and t.status<>'Voided' and c.is_fuel and extract(year from transaction_date)=p_year;
 return jsonb_build_object('year',p_year,'selected_method',method,'fuel_history',fuel,'miles_history',miles,'rate',rate,'selected_amount',case when method='Fuel' then fuel else miles*rate end,'note','One method only. Mileage rate must be supplied; no tax rate is assumed.');
end $$;
-- Only the scheduled service may bypass membership checks; authenticated users cannot choose their JWT role.
create or replace function private.require_admin(u uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.role()='service_role' then return; end if;
 if not exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid() and role='admin') then raise exception 'Administrative access required' using errcode='42501'; end if;
end $$;
create or replace function public.run_scheduled_tasks() returns void language plpgsql security definer set search_path='' as $$
declare u record; m date; j record;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required'; end if;
 update public.quotes set status='Expired' where status in ('Sent','Viewed','Agreement Pending') and expires_at<now();
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
drop policy account_read on public.physical_accounts;
create policy account_read on public.physical_accounts for select to authenticated using(
 not exists(select 1 from public.accounts a where a.physical_account_id=physical_accounts.id and not private.can_access(a.unit_id))
 and exists(select 1 from public.accounts a where a.physical_account_id=physical_accounts.id and private.can_access(a.unit_id)));
-- RLS would hide another unit's allocation inside the policy subquery; use a definer check for physical visibility.
create function private.can_view_physical(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.accounts where physical_account_id=p_id) and not exists(select 1 from public.accounts where physical_account_id=p_id and not private.can_access(unit_id));
$$;
drop policy account_read on public.physical_accounts;
create policy account_read on public.physical_accounts for select to authenticated using(private.can_view_physical(id));
grant execute on function private.can_view_physical(uuid) to authenticated;
revoke execute on function public.save_settings(jsonb),public.record_mileage(jsonb),public.save_category(jsonb),public.search_records(uuid,text),public.vehicle_report(uuid,integer) from public,anon;
grant execute on function public.save_settings(jsonb),public.record_mileage(jsonb),public.save_category(jsonb),public.search_records(uuid,text),public.vehicle_report(uuid,integer) to authenticated;
-- Read-only indexes for parent pages and worker queues.
create index quote_flow_idx on public.quotes(flow_id,revision desc);
create index quote_items_parent_idx on public.quote_items(quote_id);
create index documents_job_idx on public.documents(job_id);
create index documents_customer_idx on public.documents(customer_id);
create index documents_transaction_idx on public.documents(transaction_id);
create index collection_sale_idx on public.collections(sale_id);
create index refund_original_idx on public.refunds(original_id);
create index notification_pending_idx on public.notifications(status,due_at);
create index jobs_unit_status_idx on public.jobs(unit_id,status);
create index customers_unit_name_idx on public.customers(unit_id,lower(name));
