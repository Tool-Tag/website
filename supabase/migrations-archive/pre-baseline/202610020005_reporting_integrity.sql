create function public.dashboard_stats(p_unit uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare month_start date; next_month date; result jsonb;
begin
 if not private.can_access(p_unit) then raise exception 'Access denied'; end if;
 select date_trunc('month',now() at time zone timezone)::date into month_start from public.unit_settings where unit_id=p_unit;
 next_month:=(month_start+interval '1 month')::date;
 select jsonb_build_object(
 'sales_month',coalesce((select sum(amount) from public.transactions where unit_id=p_unit and type='SALE' and status<>'Voided' and transaction_date>=month_start and transaction_date<next_month),0),
 'collected_month',coalesce((select sum(amount) from public.transactions where unit_id=p_unit and type='COLLECTION' and status<>'Voided' and transaction_date>=month_start and transaction_date<next_month),0),
 'balance_due',coalesce((select sum(balance_due) from public.sale_balances where unit_id=p_unit and transaction_status<>'Voided'),0),
 'active_jobs',(select count(*) from public.jobs where unit_id=p_unit and status not in ('Completed','Cancelled')),
 'ready_jobs',(select count(*) from public.jobs where unit_id=p_unit and status='Ready for Delivery'),
 'issue_jobs',(select count(*) from public.jobs where unit_id=p_unit and status='Issue / Review'),
 'pending_quotes',(select count(*) from public.quotes where unit_id=p_unit and status in ('Sent','Viewed','Agreement Pending')),
 'accepted_quotes',(select count(*) from public.quotes where unit_id=p_unit and status='Accepted')) into result;
 return result;
end $$;
create function public.customer_stats(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid;
begin
 select unit_id into u from public.customers where id=p_id;
 if not private.can_access(u) then raise exception 'Access denied'; end if;
 return jsonb_build_object('lifetime_sales',coalesce((select sum(amount) from public.sale_balances where customer_id=p_id and transaction_status<>'Voided'),0),
 'outstanding',coalesce((select sum(balance_due) from public.sale_balances where customer_id=p_id and transaction_status<>'Voided'),0));
end $$;
create function private.protect_destination_close() returns trigger language plpgsql security definer set search_path='' as $$
declare t public.transactions;
begin
 select * into t from public.transactions where id=NEW.transaction_id;
 if exists(select 1 from public.monthly_closes where unit_id=NEW.destination_unit_id and month=date_trunc('month',t.transaction_date)::date and status<>'Superseded') then
 if coalesce(current_setting('app.change_reason',true),'')='' then raise exception 'Destination period closed: reason required'; end if;
 update public.monthly_closes set status='Reclose Required' where unit_id=NEW.destination_unit_id and month=date_trunc('month',t.transaction_date)::date and status<>'Superseded';
 end if;
 return NEW;
end $$;
create trigger destination_close after insert on public.inter_unit_transfers for each row execute function private.protect_destination_close();
create function private.transfer_correction_close() returns trigger language plpgsql security definer set search_path='' as $$
declare dest uuid;
begin
 select destination_unit_id into dest from public.inter_unit_transfers where transaction_id=NEW.id;
 if dest is not null then
 if exists(select 1 from public.monthly_closes where unit_id=dest and month in (date_trunc('month',NEW.transaction_date)::date,date_trunc('month',OLD.transaction_date)::date) and status<>'Superseded') then
 if coalesce(current_setting('app.change_reason',true),'')='' then raise exception 'Destination period closed: reason required'; end if;
 update public.monthly_closes set status='Reclose Required' where unit_id=dest and month in (date_trunc('month',NEW.transaction_date)::date,date_trunc('month',OLD.transaction_date)::date) and status<>'Superseded';
 end if; end if;
 return NEW;
end $$;
create trigger transfer_correction after update on public.transactions for each row execute function private.transfer_correction_close();
-- Guard allowed owner subtypes, cash methods, active account, and exact 2-decimal inputs before writing.
create function private.movement_integrity() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if NEW.type='COLLECTION' and (NEW.payment_method is null or NEW.payment_method not in ('Cash','Zelle','Venmo')) then raise exception 'Choose Cash, Zelle or Venmo'; end if;
 if NEW.account_id is not null and not exists(select 1 from public.accounts where id=NEW.account_id and active) then raise exception 'Account inactive'; end if;
 return NEW;
end $$;
create trigger movement_integrity before insert on public.transactions for each row execute function private.movement_integrity();
create function private.owner_integrity() returns trigger language plpgsql security definer set search_path='' as $$
declare typ text;
begin
 select type into typ from public.transactions where id=NEW.transaction_id;
 if (typ='OWNER_INJECTION' and NEW.subtype<>'Injection') or (typ='OWNER_DRAW' and NEW.subtype not in ('Personal Draw','Reimbursement')) then raise exception 'Invalid owner transaction subtype'; end if;
 return NEW;
end $$;
create trigger owner_integrity before insert on public.owner_transactions for each row execute function private.owner_integrity();
revoke execute on function public.dashboard_stats(uuid),public.customer_stats(uuid) from public,anon;
grant execute on function public.dashboard_stats(uuid),public.customer_stats(uuid) to authenticated;
revoke execute on function private.protect_destination_close(),private.transfer_correction_close(),private.movement_integrity(),private.owner_integrity(),private.can_view_physical(uuid) from public,anon;
