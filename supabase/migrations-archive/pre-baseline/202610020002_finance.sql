create function private.audit_change() returns trigger language plpgsql security definer set search_path='' as $$
declare oldj jsonb; newj jsonb; key text; uid uuid; eid uuid;
begin
 oldj:=case when TG_OP='INSERT' then '{}'::jsonb else to_jsonb(OLD) end;
 newj:=to_jsonb(NEW); uid:=(newj->>'unit_id')::uuid; eid:=coalesce(newj->>'id',newj->>'transaction_id',newj->>'unit_id')::uuid;
 for key in select jsonb_object_keys(newj) loop
 if newj->key is distinct from oldj->key then
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,old_value,new_value,reason)
 values(uid,auth.uid(),TG_TABLE_NAME,eid,key,oldj->key,newj->key,nullif(current_setting('app.change_reason',true),''));
 end if; end loop;
 return NEW;
end $$;
create function private.transaction_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare c public.categories; d date;
begin
 perform 1 from public.business_units where id=NEW.unit_id for update;
 if TG_OP='UPDATE' then
 if NEW.id<>OLD.id or NEW.unit_id<>OLD.unit_id or NEW.type<>OLD.type or NEW.created_at<>OLD.created_at then raise exception 'Identity, type and creation time are immutable'; end if;
 NEW.updated_at:=now();
 end if;
 if NEW.category_id is not null then
 select * into c from public.categories where id=NEW.category_id;
 if c.unit_id is not null and c.unit_id<>NEW.unit_id then raise exception 'Category belongs to another unit'; end if;
 end if;
 for d in select distinct x from unnest(array[NEW.transaction_date,case when TG_OP='UPDATE' then OLD.transaction_date else NEW.transaction_date end]) x loop
 if exists(select 1 from public.monthly_closes where unit_id=NEW.unit_id and month=date_trunc('month',d)::date and status<>'Superseded') then
 if coalesce(current_setting('app.change_reason',true),'')='' then raise exception 'Closed period: an admin reason is required'; end if;
 update public.monthly_closes set status='Reclose Required' where unit_id=NEW.unit_id and month=date_trunc('month',d)::date and status<>'Superseded';
 end if;
 end loop;
 return NEW;
end $$;
create trigger guard_transaction before insert or update on public.transactions for each row execute function private.transaction_guard();
do $$ declare t text; begin
 foreach t in array array['transactions','accounts','categories','customers','vendors','policies','quotes','quote_items','jobs','agreements','assets','documents','monthly_closes','unit_settings','sales','expenses','collections','owner_transactions','refunds','mileage'] loop
 execute format('create trigger audit_record after insert or update on public.%I for each row execute function private.audit_change()',t);
 end loop;
end $$;
create view public.expense_details with(security_invoker=true) as
 select e.*,t.amount,t.transaction_date,t.description,t.vendor,c.is_equipment,
 greatest(0,t.amount-coalesce((select sum(r.amount) from public.reimbursements r join public.transactions rt on rt.id=r.transaction_id where r.expense_id=e.transaction_id and rt.status<>'Voided'),0)
 -coalesce((select sum(ft.amount) from public.refunds f join public.transactions ft on ft.id=f.transaction_id where f.original_id=e.transaction_id and ft.status<>'Voided'),0)) as reimbursement_due,
 case when exists(select 1 from public.documents d where d.transaction_id=t.id and d.type='Receipt' and d.status='Available' and d.drive_file_id is not null) then 'Receipt Attached'
 when t.amount<75 and not e.lodging then 'Receipt Not Required (<$75)' else 'Receipt Missing — Required' end as receipt_status
 from public.expenses e join public.transactions t on t.id=e.transaction_id left join public.categories c on c.id=t.category_id where t.status<>'Voided';
create view public.sale_balances with(security_invoker=true) as
 select s.*,t.amount,t.customer_id,t.transaction_date,t.status as transaction_status,
 coalesce(p.paid,0) as collected,coalesce(f.refunded,0) as refunded,
 greatest(0,t.amount-coalesce(p.paid,0)) as balance_due,
 case when t.status='Voided' then 'Cancelled' when coalesce(f.refunded,0)>=t.amount then 'Refunded' when coalesce(f.refunded,0)>0 then 'Partially Refunded'
 when coalesce(p.paid,0)>=t.amount then 'Paid' when coalesce(p.paid,0)>0 then 'Partially Paid' else 'Open' end as status
 from public.sales s join public.transactions t on t.id=s.transaction_id
 left join lateral(select sum(ct.amount) paid from public.collections c join public.transactions ct on ct.id=c.transaction_id where c.sale_id=s.transaction_id and ct.status<>'Voided') p on true
 left join lateral(select sum(ft.amount) refunded from public.refunds r join public.transactions ft on ft.id=r.transaction_id join public.collections c on c.transaction_id=r.original_id where c.sale_id=s.transaction_id and ft.status<>'Voided') f on true;
create view public.financial_effects with(security_invoker=true) as
 select t.id,t.unit_id,t.transaction_date,t.account_id,
 case t.type when 'COLLECTION' then t.amount when 'OWNER_INJECTION' then t.amount
 when 'OWNER_DRAW' then -t.amount when 'INTER_UNIT_TRANSFER' then -t.amount
 when 'EXPENSE' then case when e.paid_by='Business' then -t.amount else 0 end
 when 'REFUND' then case when r.subtype='Customer Refund' then -t.amount when oe.paid_by='Owner' then 0 else t.amount end else 0 end as cash,
 case when t.type='SALE' then t.amount when t.type='REFUND' and r.subtype='Customer Refund' then -t.amount else 0 end as revenue,
 case when t.type='EXPENSE' and not coalesce(cat.is_equipment,false) then t.amount
 when t.type='REFUND' and r.subtype='Vendor Refund' and not coalesce(ocat.is_equipment,false) then -t.amount else 0 end as expense,
 case when t.type='EXPENSE' and cat.is_equipment then t.amount when t.type='REFUND' and r.subtype='Vendor Refund' and ocat.is_equipment then -t.amount else 0 end as equipment,
 case when t.type='OWNER_INJECTION' then t.amount else 0 end as injection
 from public.transactions t left join public.expenses e on e.transaction_id=t.id left join public.categories cat on cat.id=t.category_id
 left join public.refunds r on r.transaction_id=t.id left join public.transactions ot on ot.id=r.original_id
 left join public.expenses oe on oe.transaction_id=ot.id left join public.categories ocat on ocat.id=ot.category_id where t.status<>'Voided'
 union all
 select t.id,tr.destination_unit_id,t.transaction_date,tr.destination_account_id,t.amount,0,0,0,0
 from public.inter_unit_transfers tr join public.transactions t on t.id=tr.transaction_id where t.status<>'Voided';
-- Destination members can see the linked transfer event, without access to unrelated source transactions.
create policy transfer_destination on public.transactions for select to authenticated using(exists(select 1 from public.inter_unit_transfers i where i.transaction_id=id and private.can_access(i.destination_unit_id)));
create policy transfer_destination on public.inter_unit_transfers for select to authenticated using(private.can_access(destination_unit_id));
create view public.finance_summary with(security_invoker=true) as
 select b.id as unit_id,b.code,
 coalesce(sum(f.cash),0) operating_balance,coalesce(sum(f.revenue-f.expense),0) net_profit,
 coalesce(sum(f.equipment),0) equipment_investment,coalesce(sum(f.injection),0) owner_injection,
 coalesce((select sum(e.reimbursement_due) from public.expense_details e where e.unit_id=b.id and e.paid_by='Owner'),0) owner_reimbursement_due,
 coalesce(sum(f.cash),0)-coalesce((select sum(e.reimbursement_due) from public.expense_details e where e.unit_id=b.id and e.paid_by='Owner'),0) available_balance,
 coalesce(sum(f.revenue-f.expense-f.equipment),0) net_position
 from public.business_units b left join public.financial_effects f on f.unit_id=b.id group by b.id,b.code;
create view public.asset_details with(security_invoker=true) as
 select a.*,t.amount as purchase_cost,t.vendor,t.transaction_date as purchase_date from public.assets a left join public.transactions t on t.id=a.source_expense_id;
create view public.review_items with(security_invoker=true) as
 select unit_id,transaction_id as entity_id,'Missing Receipt'::text kind,'/app/finance/expenses'::text path from public.expense_details where receipt_status='Receipt Missing — Required'
 union all select unit_id,transaction_id,'Unregistered Equipment Purchase','/app/equipment' from public.expense_details where is_equipment and linked_asset_id is null
 union all select c.unit_id,c.transaction_id,'Unlinked Collection','/app/finance/transactions' from public.collections c join public.transactions t on t.id=c.transaction_id where c.sale_id is null and t.status<>'Voided'
 union all select unit_id,id,status,'/app/finance/reports' from public.monthly_closes where status in ('Reclose Required','Documentation Updated')
 union all select unit_id,transaction_id,'Owner Reimbursement Pending','/app/finance/expenses' from public.expense_details where paid_by='Owner' and reimbursement_due>0
 union all select unit_id,id,'Quote expiring','/app/quotes/'||id from public.quotes where status in ('Sent','Viewed') and expires_at<now()+interval '2 days'
 union all select unit_id,id,'Completion acknowledgment pending','/app/jobs/'||id from public.jobs where status='Delivered – Pending Customer Acceptance'
 union all select j.unit_id,j.id,'Receiving photos missing','/app/jobs/'||j.id from public.jobs j where status in ('Authorized','Receiving Documentation') and not exists(select 1 from public.documents d where d.job_id=j.id and d.type='Receiving Evidence' and d.status='Available');
grant select on public.expense_details,public.sale_balances,public.financial_effects,public.finance_summary,public.asset_details,public.review_items to authenticated;
create function public.record_movement(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; typ text:=p->>'type'; tid uuid; amt numeric(14,2):=(p->>'amount')::numeric;
 a uuid:=(p->>'account_id')::uuid; cat public.categories; original public.transactions; due numeric; rec record; remaining numeric; alloc numeric; sale public.transactions;
begin
 perform private.require_admin(u);
 perform 1 from public.business_units where id=u for update; -- serialize unit financial mutations
 perform set_config('app.change_reason',coalesce(p->>'reason',''),true);
 if typ not in ('COLLECTION','EXPENSE','OWNER_INJECTION','OWNER_DRAW','INTER_UNIT_TRANSFER','REFUND') then raise exception 'Unsupported movement'; end if;
 if amt is null or amt<=0 or (p->>'amount')::numeric<>amt then raise exception 'Positive amount with at most two decimal places required'; end if;
 if typ='EXPENSE' then
 select * into cat from public.categories where id=(p->>'category_id')::uuid and kind='expense' and active and (unit_id=u or unit_id is null);
 if cat.id is null or nullif(trim(p->>'vendor'),'') is null then raise exception 'Expense category and vendor required'; end if;
 end if;
 if typ='COLLECTION' and nullif(p->>'sale_id','') is not null then
 select t.* into sale from public.transactions t join public.sales s on s.transaction_id=t.id where t.id=(p->>'sale_id')::uuid and t.unit_id=u and t.status<>'Voided' for update of t;
 if sale.id is null then raise exception 'Sale not found'; end if;
 select balance_due into due from public.sale_balances where transaction_id=sale.id;
 if amt>due then raise exception 'Collection exceeds outstanding sale balance'; end if;
 if p->>'payment_method' not in ('Cash','Zelle','Venmo') or p->>'payment_method' is null then raise exception 'Choose Cash, Zelle or Venmo'; end if;
 end if;
 if typ='OWNER_DRAW' and p->>'subtype'='Reimbursement' then
 select coalesce(sum(reimbursement_due),0) into due from public.expense_details where unit_id=u and paid_by='Owner';
 if amt>due then raise exception 'Reimbursement exceeds outstanding amount'; end if;
 end if;
 if typ='REFUND' then
 select * into original from public.transactions where id=(p->>'original_id')::uuid and unit_id=u and status<>'Voided' for update;
 if original.id is null or original.type not in ('COLLECTION','EXPENSE') then raise exception 'Refund must link to a collection or expense'; end if;
 select original.amount-coalesce(sum(t.amount),0) into due from public.refunds r join public.transactions t on t.id=r.transaction_id where r.original_id=original.id and t.status<>'Voided';
 if original.type='EXPENSE' then
 if exists(select 1 from public.expenses where transaction_id=original.id and paid_by='Owner') then
 select reimbursement_due into due from public.expense_details where transaction_id=original.id;
 end if; end if;
 if amt>due then raise exception 'Refund exceeds eligible amount paid (or owner amount outstanding)'; end if;
 if original.type='COLLECTION' and coalesce((p->>'transaction_date')::date,current_date)>original.transaction_date+14 and nullif(trim(p->>'reason'),'') is null then raise exception 'Refund outside 14 days requires admin reason'; end if;
 end if;
 if typ='INTER_UNIT_TRANSFER' then
 perform private.require_admin((p->>'destination_unit_id')::uuid);
 if not exists(select 1 from public.accounts s join public.accounts d on d.physical_account_id=s.physical_account_id where s.id=a and s.unit_id=u and d.id=(p->>'destination_account_id')::uuid and d.unit_id=(p->>'destination_unit_id')::uuid and s.unit_id<>d.unit_id) then raise exception 'Allocation transfer requires two units sharing the same physical bank'; end if;
 end if;
 insert into public.transactions(unit_id,type,transaction_date,amount,account_id,category_id,customer_id,vendor,description,payment_method,reference,created_by)
 values(u,typ,coalesce((p->>'transaction_date')::date,current_date),amt,a,nullif(p->>'category_id','')::uuid,coalesce(sale.customer_id,nullif(p->>'customer_id','')::uuid),p->>'vendor',p->>'description',nullif(p->>'payment_method',''),p->>'reference',auth.uid()) returning id into tid;
 if typ='EXPENSE' then
 insert into public.expenses(transaction_id,unit_id,paid_by,lodging) values(tid,u,coalesce(p->>'paid_by','Business'),coalesce((p->>'lodging')::boolean,false));
 insert into public.vendors(unit_id,name) values(u,trim(p->>'vendor')) on conflict do nothing;
 elsif typ='COLLECTION' then
 insert into public.collections values(tid,u,nullif(p->>'sale_id','')::uuid);
 insert into public.documents(unit_id,type,file_name,transaction_id,customer_id,content_snapshot,uploaded_by)
 values(u,'Payment Receipt','Receipt-'||tid||'.json',tid,sale.customer_id,
 jsonb_build_object('amount',amt,'payment_method',p->>'payment_method','date',coalesce((p->>'transaction_date')::date,current_date),'sale_id',sale.id,
 'sale_total',sale.amount,'sale_code',(select code from public.sales where transaction_id=sale.id),'job_id',(select job_id from public.sales where transaction_id=sale.id),
 'paid_to_date',(select collected from public.sale_balances where transaction_id=sale.id),'balance_remaining',(select balance_due from public.sale_balances where transaction_id=sale.id)),auth.uid());
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values(u,'Payment receipt',tid,'payment:'||tid,jsonb_build_object('sale_id',sale.id));
 if exists(select 1 from public.sale_balances where transaction_id=sale.id and status='Paid') then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(u,'Final Paid receipt',sale.id,'paid:'||tid);
 end if;
 elsif typ in ('OWNER_INJECTION','OWNER_DRAW') then
 insert into public.owner_transactions values(tid,u,case when typ='OWNER_INJECTION' then 'Injection' else coalesce(p->>'subtype','Personal Draw') end);
 if p->>'subtype'='Reimbursement' then
 remaining:=amt;
 for rec in select * from public.expense_details where unit_id=u and paid_by='Owner' and reimbursement_due>0 order by transaction_date,transaction_id loop
 alloc:=least(remaining,rec.reimbursement_due);
 insert into public.reimbursements values(tid,rec.transaction_id,u,alloc); remaining:=remaining-alloc;
 exit when remaining=0;
 end loop;
 end if;
 elsif typ='INTER_UNIT_TRANSFER' then insert into public.inter_unit_transfers values(tid,u,(p->>'destination_unit_id')::uuid,(p->>'destination_account_id')::uuid);
 elsif typ='REFUND' then insert into public.refunds values(tid,u,original.id,case when original.type='COLLECTION' then 'Customer Refund' else 'Vendor Refund' end,p->>'reason');
 end if;
 return tid;
end $$;
create function public.create_asset(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; eid uuid:=nullif(p->>'source_expense_id','')::uuid; aid uuid;
begin
 perform private.require_admin(u);
 if p->>'origin'='Purchased' then
 perform 1 from public.expenses where transaction_id=eid and unit_id=u for update;
 if not exists(select 1 from public.expense_details where transaction_id=eid and unit_id=u and is_equipment and linked_asset_id is null) then raise exception 'Choose an unlinked equipment expense'; end if;
 end if;
 if not exists(select 1 from public.categories where id=(p->>'category_id')::uuid and kind='asset' and (unit_id=u or unit_id is null) and active) then raise exception 'Asset category required'; end if;
 insert into public.assets(unit_id,source_expense_id,origin,name,category_id,serial_number,warranty_expiration,notes,estimated_value,donated_by,received_date)
 values(u,eid,p->>'origin',p->>'name',(p->>'category_id')::uuid,p->>'serial_number',nullif(p->>'warranty_expiration','')::date,p->>'notes',nullif(p->>'estimated_value','')::numeric,nullif(p->>'donated_by',''),nullif(p->>'received_date','')::date) returning id into aid;
 if eid is not null then update public.expenses set linked_asset_id=aid where transaction_id=eid; end if;
 return aid;
end $$;
create function public.close_month(p_unit uuid,p_month date) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid; ver integer; snap jsonb; warnings jsonb;
begin
 perform private.require_admin(p_unit);
 perform 1 from public.business_units where id=p_unit for update;
 if p_month<>date_trunc('month',p_month)::date or p_month>=date_trunc('month',current_date)::date then raise exception 'Choose a completed calendar month'; end if;
 select coalesce(max(version),0)+1 into ver from public.monthly_closes where unit_id=p_unit and month=p_month;
 select jsonb_build_object('revenue',coalesce(sum(revenue),0),'expenses',coalesce(sum(expense),0),'equipment',coalesce(sum(equipment),0),'cash_change',coalesce(sum(cash),0),
 'transactions',coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where unit_id=p_unit and transaction_date>=p_month and transaction_date<p_month+interval '1 month'),'[]'::jsonb),
 'current_summary',(select to_jsonb(s) from public.finance_summary s where unit_id=p_unit)) into snap
 from public.financial_effects where unit_id=p_unit and transaction_date>=p_month and transaction_date<p_month+interval '1 month';
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') into warnings from public.review_items r where unit_id=p_unit;
 update public.monthly_closes set status='Superseded' where unit_id=p_unit and month=p_month and status<>'Superseded';
 insert into public.monthly_closes(unit_id,month,version,status,snapshot,warnings,created_by) values(p_unit,p_month,ver,'Current',snap,warnings,auth.uid()) returning id into cid;
 return cid;
end $$;
create function public.update_transaction(p jsonb) returns void language plpgsql security definer set search_path='' as $$
declare t public.transactions;
begin
 select * into t from public.transactions where id=(p->>'id')::uuid for update;
 perform private.require_admin(t.unit_id);
 if nullif(trim(p->>'reason'),'') is null then raise exception 'Change reason required'; end if;
 perform set_config('app.change_reason',p->>'reason',true);
 -- Monetary corrections use reversals/refunds, preserving accepted sale and payment snapshots.
 if p->>'status'='Voided' and (t.type='SALE' or exists(select 1 from public.refunds where original_id=t.id) or exists(select 1 from public.reimbursements where expense_id=t.id) or exists(select 1 from public.assets where source_expense_id=t.id)) then raise exception 'Linked transaction cannot be voided; use a revision or refund'; end if;
 update public.transactions set transaction_date=coalesce((p->>'transaction_date')::date,transaction_date),description=coalesce(p->>'description',description),status=coalesce(p->>'status',status) where id=t.id;
end $$;
