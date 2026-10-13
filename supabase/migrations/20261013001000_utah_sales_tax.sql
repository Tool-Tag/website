-- Local-only additive migration. Preserve already sent/accepted commercial snapshots.
begin;
alter table public.unit_settings add column sales_tax_rate numeric(6,3) not null default 7.45 check(sales_tax_rate between 0 and 100);
alter table public.quotes add column tax_rate numeric(6,3) not null default 0 check(tax_rate between 0 and 100);
alter table public.quote_logistics add column fee_subtotal numeric(14,2), add column fee_tax_rate numeric(6,3) not null default 0 check(fee_tax_rate between 0 and 100);
alter table public.job_extensions add column tax_rate numeric(6,3) not null default 0 check(tax_rate between 0 and 100), add column tax_snapshot jsonb;
alter table public.sales add column tax_snapshot jsonb;
alter table public.sale_versions add column tax_snapshot jsonb;
create function private.tax_details(p_subtotal numeric,p_rate numeric) returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object('subtotal',round(p_subtotal,2),'tax_rate',p_rate,'tax_amount',round(p_subtotal*p_rate/100,2),'total',round(p_subtotal,2)+round(p_subtotal*p_rate/100,2),'tax_notice','Price subject to taxes — final total includes Utah sales tax.');
$$;
revoke all on function private.tax_details(numeric,numeric) from public,anon,authenticated;
create function public.sales_tax_rate() returns numeric language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_any('10000000-0000-0000-0000-000000000002',array['quotes.view','quotes.manage','settings.manage']) then raise exception 'Quote access required' using errcode='42501';end if;
 return (select sales_tax_rate from public.unit_settings where unit_id='10000000-0000-0000-0000-000000000002');
end$$;
create function public.save_sales_tax_rate(p_rate numeric) returns void language plpgsql security definer set search_path='' as $$begin
 perform private.require_owner('10000000-0000-0000-0000-000000000002');
 if p_rate is null or p_rate<0 or p_rate>100 or p_rate<>round(p_rate,3) then raise exception 'Tax rate must be between 0 and 100, with at most three decimal places';end if;
 update public.unit_settings set sales_tax_rate=p_rate where unit_id='10000000-0000-0000-0000-000000000002';
 update public.quotes set tax_rate=p_rate where unit_id='10000000-0000-0000-0000-000000000002' and status='Draft';
 update public.job_extensions set tax_rate=p_rate where unit_id='10000000-0000-0000-0000-000000000002' and status in ('Requested','Draft');
 perform private.rbac_log('settings.sales_tax.saved','10000000-0000-0000-0000-000000000002',jsonb_build_object('rate',p_rate));
end$$;
revoke all on function public.sales_tax_rate(),public.save_sales_tax_rate(numeric) from public,anon;
grant execute on function public.sales_tax_rate(),public.save_sales_tax_rate(numeric) to authenticated;
create function private.quote_tax_rate() returns trigger language plpgsql security definer set search_path='' as $$begin
 if TG_OP='INSERT' and new.unit_id='10000000-0000-0000-0000-000000000002' then
 select sales_tax_rate into new.tax_rate from public.unit_settings where unit_id=new.unit_id;
 elsif TG_OP='UPDATE' and old.status<>'Draft' and new.tax_rate is distinct from old.tax_rate then raise exception 'Sent or accepted Quote tax rate is immutable';end if;
 return new;
end$$;
create trigger quote_tax_rate before insert or update of tax_rate on public.quotes for each row execute function private.quote_tax_rate();
update public.quotes q set tax_rate=s.sales_tax_rate from public.unit_settings s where q.unit_id=s.unit_id and q.unit_id='10000000-0000-0000-0000-000000000002' and q.status='Draft';
-- Existing fees remain unchanged; only newly selected logistics are taxed.
update public.quote_logistics set fee_subtotal=fee_amount;
alter table public.quote_logistics drop constraint quote_logistics_fee_check;
alter table public.quote_logistics add constraint quote_logistics_fee_check check(fee_subtotal in (0,9.99,19.99)), add constraint quote_logistics_tax_total_check check(fee_amount=fee_subtotal+round(fee_subtotal*fee_tax_rate/100,2));
create function private.logistics_tax_fee() returns trigger language plpgsql security definer set search_path='' as $$declare rate numeric;begin
 if TG_OP='INSERT' then
 select tax_rate into rate from public.quotes where id=new.quote_id;
 new.fee_subtotal:=new.fee_amount;new.fee_tax_rate:=coalesce(rate,0);
 new.fee_amount:=new.fee_subtotal+round(new.fee_subtotal*coalesce(rate,0)/100,2);
 end if;
 return new;
end$$;
create trigger logistics_tax_fee before insert on public.quote_logistics for each row execute function private.logistics_tax_fee();
create function private.pickup_tax_fee() returns trigger language plpgsql security definer set search_path='' as $$declare gross numeric;begin
 select l.fee_amount into gross from public.jobs j join public.quote_logistics l on l.quote_id=j.quote_id where j.id=new.job_id;
 if gross is not null then new.fee_amount:=gross;end if;return new;
end$$;
create trigger pickup_tax_fee before insert or update of fee_amount on public.pick_return_orders for each row execute function private.pickup_tax_fee();
-- Preserve existing snapshot implementation, adding the pinned tax breakdown.
alter function private.quote_snapshot(uuid) rename to quote_snapshot_before_tax;
do $$declare d text;begin
 select pg_get_functiondef('private.quote_snapshot_before_tax(uuid)'::regprocedure) into d;
 d:=replace(d,'l.fee_amount','coalesce(l.fee_subtotal,l.fee_amount)');execute d;
end$$;
create function private.quote_snapshot(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$declare s jsonb;r numeric;option_code text;option_data jsonb;begin
 s:=private.quote_snapshot_before_tax(p_id);select tax_rate into r from public.quotes where id=p_id;
 if not exists(select 1 from public.quote_logistics where quote_id=p_id) then
 option_code:=private.logistics_predefined(p_id);
 if option_code is not null then option_data:=private.logistics_option(option_code);s:=s||jsonb_build_object('total',(s->>'total')::numeric+(option_data->>'fee')::numeric,'items',(s->'items')||jsonb_build_array(jsonb_build_object('article','Logistics — '||(option_data->>'name'),'quantity',1,'unit_price',(option_data->>'fee')::numeric,'engraving_type','Fee','marks','[]'::jsonb,'pricing',jsonb_build_object('kind','logistics_service'))));end if;
 end if;
 return s||private.tax_details((s->>'total')::numeric,coalesce(r,0));
end$$;
revoke all on function private.quote_snapshot(uuid),private.quote_snapshot_before_tax(uuid) from public,anon,authenticated;
do $$declare d text;begin
 select pg_get_functiondef('public.public_quote(text)'::regprocedure) into d;
 if position('return snap||jsonb_build_object(' in d)=0 then raise exception 'Unexpected public quote body';end if;
 d:=replace(d,'return snap||jsonb_build_object(', 'if a.id is null then snap:=snap||private.tax_details(base_total,q.tax_rate);end if; return snap||jsonb_build_object(');execute d;
 select pg_get_functiondef('public.accept_agreement(text,text,text,text)'::regprocedure) into d;
 if position('select id into jid from public.jobs where flow_id=f.id;' in d)=0 then raise exception 'Unexpected acceptance body';end if;
 d:=replace(d,'l.fee_amount','coalesce(l.fee_subtotal,l.fee_amount)');
 d:=replace(d,'select id into jid from public.jobs where flow_id=f.id;','total:=total+round(total*q.tax_rate/100,2); select id into jid from public.jobs where flow_id=f.id;');execute d;
end$$;
-- Extensions pin their own rate and preserve accepted snapshots.
create function private.extension_tax() returns trigger language plpgsql security definer set search_path='' as $$declare subtotal numeric;begin
 if TG_OP='INSERT' and new.unit_id='10000000-0000-0000-0000-000000000002' then select sales_tax_rate into new.tax_rate from public.unit_settings where unit_id=new.unit_id;end if;
 if new.status in ('Requested','Draft') then
 select coalesce(sum((i->>'quantity')::numeric*(i->>'unit_price')::numeric),0) into subtotal from jsonb_array_elements(coalesce(new.items,'[]')) i;
 new.tax_snapshot:=private.tax_details(subtotal,new.tax_rate);new.total:=(new.tax_snapshot->>'total')::numeric;
 elsif TG_OP='UPDATE' and new.tax_rate is distinct from old.tax_rate then raise exception 'Sent extension tax is immutable';end if;
 return new;
end$$;
create trigger extension_tax before insert or update of items,total,tax_rate on public.job_extensions for each row execute function private.extension_tax();
update public.job_extensions x set tax_rate=s.sales_tax_rate from public.unit_settings s where x.unit_id=s.unit_id and x.unit_id='10000000-0000-0000-0000-000000000002' and x.status in ('Requested','Draft');
revoke all on function private.extension_tax() from public,anon,authenticated;
do $$declare d text;begin
 select pg_get_functiondef('public.save_job_extension(jsonb)'::regprocedure) into d;
 if position('total=total,status' in d)=0 then raise exception 'Unexpected extension pricing body';end if;
 d:=replace(d,'total numeric','extension_subtotal numeric');d:=replace(d,'into total from','into extension_subtotal from');d:=replace(d,'if total<=0','if extension_subtotal<=0');d:=replace(d,'total=total,status','total=extension_subtotal,status');execute d;
 select pg_get_functiondef('public.public_extension(text,boolean,text)'::regprocedure) into d;
 d:=replace(d,'snap:=jsonb_build_object(''extension_id''','snap:=coalesce(x.tax_snapshot,''{}''::jsonb)||jsonb_build_object(''extension_id''');
 d:=replace(d,'return jsonb_build_object(''code'',x.code','return coalesce(x.tax_snapshot,''{}''::jsonb)||jsonb_build_object(''code'',x.code');execute d;
end$$;

-- A second logistics trip is taxable using the original Job's pinned rate.
do $$declare d text;begin
 select pg_get_functiondef('public.choose_second_return(uuid,text)'::regprocedure) into d;
 if position('select second_delivery_attempt_fee into fee from public.unit_settings where unit_id=j.unit_id;' in d)=0 then raise exception 'Unexpected retry fee body';end if;
 d:=replace(d,'select second_delivery_attempt_fee into fee from public.unit_settings where unit_id=j.unit_id;','select second_delivery_attempt_fee into fee from public.unit_settings where unit_id=j.unit_id; fee:=fee+round(fee*(select tax_rate from public.quotes where id=j.quote_id)/100,2);');execute d;
end$$;

-- Existing lock also covers the new accepted tax metadata.
do $$declare d text;begin
 select pg_get_functiondef('private.lock_quote_logistics()'::regprocedure) into d;
 d:=replace(d,'or new.fee_amount is distinct from old.fee_amount','or new.fee_amount is distinct from old.fee_amount or new.fee_subtotal is distinct from old.fee_subtotal or new.fee_tax_rate is distinct from old.fee_tax_rate');execute d;
 -- Card allocation must include taxable second-trip balances, like manual payments.
 select pg_get_functiondef('public.confirm_logistics_card_payment(uuid,text,numeric)'::regprocedure) into d;
 if position('select 1000' in d)=0 then
 d:=replace(d,'and s.balance_due>0
    ) x','and s.balance_due>0
      union all select 1000,s.transaction_id,s.balance_due,s.customer_id from public.delivery_attempt_fees df join public.sale_balances s on s.transaction_id=df.sale_id where df.job_id=j.id and s.transaction_status<>''Voided'' and s.balance_due>0
    ) x');
 if position('select 1000' in d)=0 then raise exception 'Unexpected card allocation body';end if;
 execute d;end if;
end$$;

-- Accepted ledger versions carry explicit tax metadata for reproducible audit.
create function private.sale_tax_snapshot() returns trigger language plpgsql security definer set search_path='' as $$declare rate numeric;base numeric;snapshot jsonb;begin
 if new.quote_id is not null then snapshot:=private.quote_snapshot(new.quote_id);new.tax_snapshot:=jsonb_build_object('subtotal',snapshot->'subtotal','tax_rate',snapshot->'tax_rate','tax_amount',snapshot->'tax_amount','total',snapshot->'total');
 elsif TG_TABLE_NAME='sales' then select x.tax_snapshot into new.tax_snapshot from public.job_extensions x where x.unit_id=new.unit_id and replace(x.code,'TT-J-','TT-S-')=new.code;
 if new.tax_snapshot is null then select q.tax_rate,u.second_delivery_attempt_fee into rate,base from public.jobs j join public.quotes q on q.id=j.quote_id join public.unit_settings u on u.unit_id=j.unit_id where j.unit_id=new.unit_id and new.code=j.code||'/RETURN2';if rate is not null then new.tax_snapshot:=private.tax_details(base,rate);end if;end if;end if;return new;
end$$;
create trigger sale_tax_snapshot before insert or update of quote_id on public.sales for each row execute function private.sale_tax_snapshot();
create trigger sale_version_tax_snapshot before insert on public.sale_versions for each row execute function private.sale_tax_snapshot();
create function private.transaction_sales_tax(p_id uuid) returns numeric language sql stable set search_path='' as $$
 select coalesce(round(t.amount*coalesce((coalesce(s.tax_snapshot,rs.tax_snapshot)->>'tax_amount')::numeric,0)/nullif((coalesce(s.tax_snapshot,rs.tax_snapshot)->>'total')::numeric,0),2),0)
 from public.transactions t left join public.sales s on s.transaction_id=t.id left join public.refunds r on r.transaction_id=t.id left join public.collections c on c.transaction_id=r.original_id left join public.sales rs on rs.transaction_id=c.sale_id where t.id=p_id;
$$;
revoke all on function private.transaction_sales_tax(uuid) from public,anon;
grant execute on function private.transaction_sales_tax(uuid) to authenticated,service_role;

create function private.job_tax_details(p_job uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('subtotal',coalesce(sum(t.amount-private.transaction_sales_tax(t.id)),0),'tax_amount',coalesce(sum(private.transaction_sales_tax(t.id)),0),'tax_rate',coalesce(max((s.tax_snapshot->>'tax_rate')::numeric),0),'tax_rates',jsonb_agg(distinct coalesce((s.tax_snapshot->>'tax_rate')::numeric,0)),'total',coalesce(sum(t.amount),0))
 from public.sales s join public.transactions t on t.id=s.transaction_id
 where t.status<>'Voided' and (s.job_id=p_job or s.transaction_id in(select sale_id from public.job_extensions where job_id=p_job and status in('Approved','Completed')) or s.transaction_id in(select sale_id from public.delivery_attempt_fees where job_id=p_job));
$$;
revoke all on function private.job_tax_details(uuid) from public,anon,authenticated;
create function public.public_payment_tax(p_token text,p_scope text) returns jsonb language plpgsql security definer set search_path='' as $$declare data jsonb;j public.jobs;pid uuid;amount numeric;r numeric;begin
 if p_scope='review-fee' then
 data:=public.public_logistics_payment(p_token);select q.tax_rate,l.fee_subtotal into r,amount from public.quotes q join public.quote_logistics l on l.quote_id=q.id where l.job_id=(data->>'job_id')::uuid;
 return private.tax_details(coalesce(amount,(data->>'fee_amount')::numeric),coalesce(r,0))||jsonb_build_object('total',(data->>'fee_amount')::numeric);
 elsif p_scope='review' then
 data:=public.public_quote(p_token);select a.job_id into pid from public.agreements a where a.quote_id=(data->>'id')::uuid;
 elsif p_scope='completion' then data:=public.public_completion(p_token);pid:=(data->>'id')::uuid;
 elsif p_scope='status' then j:=private.audit_status_job(p_token);pid:=j.id;
 elsif p_scope='pickup' then
 data:=public.public_pickup_fee(p_token);
 select job_id into pid from private.pickup_payment_links where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and expires_at>now();
 select q.tax_rate into r from public.jobs j0 join public.quotes q on q.id=j0.quote_id where j0.id=pid;
 amount:=(data->>'amount')::numeric;return private.tax_details(round(amount/(1+coalesce(r,0)/100),2),coalesce(r,0))||jsonb_build_object('total',amount);
 else raise exception 'Invalid payment scope';end if;
 if pid is null then raise exception 'Payment link unavailable';end if;
 return private.job_tax_details(pid);
end$$;
revoke all on function public.public_payment_tax(text,text) from public;
grant execute on function public.public_payment_tax(text,text) to anon,authenticated;
-- Cash/receivables remain tax-inclusive; sales tax is not operating revenue.
do $$declare summary text;begin
 summary:=pg_get_viewdef('public.finance_summary'::regclass,true);
 alter view public.financial_effects rename to financial_effects_before_tax;
 create view public.financial_effects with(security_invoker=true) as select f.id,f.unit_id,f.transaction_date,f.account_id,f.cash,
 case when t.type='SALE' or (t.type='REFUND' and r.subtype='Customer Refund') then f.revenue-sign(f.revenue)*private.transaction_sales_tax(f.id) else f.revenue end as revenue,
 f.expense,f.equipment,f.injection from public.financial_effects_before_tax f join public.transactions t on t.id=f.id left join public.refunds r on r.transaction_id=t.id;
 execute 'create or replace view public.finance_summary with(security_invoker=true) as '||summary;
end$$;
grant select on public.financial_effects to authenticated,service_role;

revoke all on function private.quote_tax_rate(),private.logistics_tax_fee(),private.pickup_tax_fee(),private.sale_tax_snapshot() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
