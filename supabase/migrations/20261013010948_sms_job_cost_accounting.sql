-- Additive, prospective SMS costing. No sends, payments or historical replay.
begin;
alter table public.unit_settings add column sms_unit_cost numeric(12,8) not null default 0.00645 check(sms_unit_cost>=0), add column sms_expense_account_id uuid references public.accounts(id);
update public.unit_settings s set sms_expense_account_id=(select id from public.accounts where unit_id=s.unit_id and active order by name,id limit 1) where s.unit_id='10000000-0000-0000-0000-000000000002';
insert into public.categories(unit_id,name,kind) select '10000000-0000-0000-0000-000000000002','SMS','expense' where not exists(select 1 from public.categories where unit_id='10000000-0000-0000-0000-000000000002' and name='SMS' and kind='expense');
alter table private.sms_deliveries add column costing_quote_id uuid, add column costing_quote_code text, add column costing_rate numeric(12,8);
-- Retain origin identifiers/codes even when operational records are deleted.
create table public.sms_cost_totals(
 id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.business_units(id),flow_id uuid not null unique,
 quote_id uuid references public.quotes(id) on delete set null,quote_code text not null,job_id uuid references public.jobs(id) on delete set null,job_code text,
 sms_count integer not null default 0 check(sms_count>=0),delivered_count integer not null default 0,delivery_failed_count integer not null default 0,delivery_unknown_count integer not null default 0,acceptance_unknown_count integer not null default 0,exact_cost numeric(18,8) not null default 0 check(exact_cost>=0),posted_amount numeric(14,2) not null default 0 check(posted_amount>=0),
 closed_at timestamptz,close_reason text,posting_error text,updated_at timestamptz not null default now()
);
create table private.sms_cost_usage(
 notification_id uuid primary key,unit_id uuid not null,flow_id uuid not null,origin_quote_id uuid,origin_quote_code text not null,
 provider_id text not null,accepted_at timestamptz not null,delivery_status text not null default 'Unknown' check(delivery_status in ('Unknown','Delivered','Failed')),delivery_reason text,delivery_observed_at timestamptz,unit_cost numeric(12,8) not null check(unit_cost>=0),unique(unit_id,provider_id)
);
create index sms_cost_usage_flow on private.sms_cost_usage(flow_id);
alter table private.sms_cost_usage enable row level security;
revoke all on private.sms_cost_usage from public,anon,authenticated;
alter table public.sms_cost_totals enable row level security;
revoke all on public.sms_cost_totals from public,anon,authenticated;
grant select on public.sms_cost_totals to authenticated;
create policy sms_cost_totals_read on public.sms_cost_totals for select to authenticated using(private.has_block(unit_id,'payments.view'));
-- Frozen per-posting trace metadata, separate from editable business descriptions.
alter table public.expenses add column sms_cost_total_id uuid references public.sms_cost_totals(id),add column sms_cost_snapshot jsonb;
create index expenses_sms_cost_total on public.expenses(sms_cost_total_id) where sms_cost_total_id is not null;

create function private.post_sms_cost(p_total uuid) returns void language plpgsql security definer set search_path='' as $$
declare a public.sms_cost_totals;settings public.unit_settings;cat uuid;tid uuid;delta numeric;ref text;snapshot jsonb;
begin
 select * into a from public.sms_cost_totals where id=p_total for update;
 if a.id is null or a.closed_at is null then return;end if;
 delta:=round(a.exact_cost,2)-a.posted_amount;
 if delta<=0 then return;end if;
 select * into settings from public.unit_settings where unit_id=a.unit_id;
 if not exists(select 1 from public.accounts where id=settings.sms_expense_account_id and unit_id=a.unit_id and active) then update public.sms_cost_totals set posting_error='Select an active SMS expense account in Settings' where id=a.id;return;end if;
 select id into cat from public.categories where unit_id=a.unit_id and name='SMS' and kind='expense' and active order by id limit 1;
 if cat is null then update public.sms_cost_totals set posting_error='Reactivate the SMS expense category' where id=a.id;return;end if;
 ref:=case when a.job_code is not null then 'SMS-JOB-'||a.job_code else 'SMS-Quote-'||a.quote_code end;
 snapshot:=jsonb_build_object('flow_id',a.flow_id,'quote_id',a.quote_id,'quote_code',a.quote_code,'job_id',a.job_id,'job_code',a.job_code,'sms_count',a.sms_count,'acceptance_basis','AWS MessageId','delivered_at_posting',a.delivered_count,'delivery_failed_at_posting',a.delivery_failed_count,'delivery_unknown_at_posting',a.delivery_unknown_count,'exact_cost',a.exact_cost,'cumulative_posted',round(a.exact_cost,2),'posted_delta',delta,'origins',(select jsonb_agg(x) from(select origin_quote_id,origin_quote_code,count(*) as sms_count,sum(unit_cost) as exact_cost from private.sms_cost_usage where flow_id=a.flow_id group by origin_quote_id,origin_quote_code)x),'rates',(select jsonb_agg(x) from(select unit_cost,count(*) as sms_count,sum(unit_cost) as exact_cost from private.sms_cost_usage where flow_id=a.flow_id group by unit_cost order by unit_cost)x));
 insert into public.transactions(unit_id,type,transaction_date,amount,account_id,category_id,vendor,description,reference)
 values(a.unit_id,'EXPENSE',(now() at time zone 'America/Denver')::date,delta,settings.sms_expense_account_id,cat,'AWS SNS','SMS · '||coalesce(a.job_code,a.quote_code)||' · '||a.sms_count||' AWS accepted',ref) returning id into tid;
 insert into public.expenses(transaction_id,unit_id,paid_by,lodging,sms_cost_total_id,sms_cost_snapshot) values(tid,a.unit_id,'Business',false,a.id,snapshot);
 update public.sms_cost_totals set posted_amount=round(exact_cost,2),posting_error=null,updated_at=now() where id=a.id;
end$$;

create function private.try_post_sms_cost(p_total uuid) returns void language plpgsql security definer set search_path='' as $$begin
 begin perform private.post_sms_cost(p_total);exception when others then update public.sms_cost_totals set posting_error='Accounting posting failed; pending retry',updated_at=now() where id=p_total;end;
end$$;
create function private.attach_sms_cost(p_flow uuid,p_quote uuid,p_code text) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.sms_cost_totals;j public.jobs;
begin
 insert into public.sms_cost_totals(unit_id,flow_id,quote_id,quote_code) values('10000000-0000-0000-0000-000000000002',p_flow,p_quote,p_code) on conflict(flow_id) do nothing;
 select * into a from public.sms_cost_totals where flow_id=p_flow for update;
 select * into j from public.jobs where flow_id=p_flow and unit_id=a.unit_id;
 if j.id is not null then
 update public.sms_cost_totals set job_id=j.id,job_code=j.code,quote_id=j.quote_id,quote_code=(select code from public.quotes where id=j.quote_id),closed_at=case when j.status in ('Completed','Cancelled') or j.work_stage='Closed' then coalesce(closed_at,now()) else null end,close_reason=case when j.status in ('Completed','Cancelled') or j.work_stage='Closed' then 'Job terminal' else null end,updated_at=now() where id=a.id;
 -- Late conversion after a previous Quote expense reattributes its trace, never charges it twice.
 else
 if not exists(select 1 from public.quotes where flow_id=p_flow and status in ('Draft','Sent','Viewed','Agreement Pending','Accepted')) then update public.sms_cost_totals set closed_at=coalesce(closed_at,now()),close_reason=coalesce(close_reason,'Quote expired'),updated_at=now() where id=a.id;end if;
 end if;
 return a.id;
end$$;

create function private.sms_cost_prepare() returns trigger language plpgsql security definer set search_path='' as $$
declare q public.quotes;fid uuid;
begin
 if new.status<>'Sending' or old.status='Sending' or new.flow_id is null then return new;end if;
 select x.* into q from public.quotes x join public.notifications n on n.entity_id=x.id where n.id=new.notification_id;
 if q.id is null then select x.* into q from public.quotes x join public.jobs j on j.quote_id=x.id where j.flow_id=new.flow_id;end if;
 if q.id is null then select * into q from public.quotes where flow_id=new.flow_id order by revision desc,created_at desc limit 1;end if;
 if q.id is not null and q.unit_id='10000000-0000-0000-0000-000000000002' then
 new.costing_quote_id:=q.id;new.costing_quote_code:=q.code;select sms_unit_cost into new.costing_rate from public.unit_settings where unit_id=q.unit_id;
 end if;return new;
end$$;
create trigger sms_cost_prepare before update of status on private.sms_deliveries for each row execute function private.sms_cost_prepare();
create function private.refresh_sms_cost_delivery(p_flow uuid) returns void language sql security definer set search_path='' as $$
 update public.sms_cost_totals set delivered_count=(select count(*) from private.sms_cost_usage where flow_id=p_flow and delivery_status='Delivered'),delivery_failed_count=(select count(*) from private.sms_cost_usage where flow_id=p_flow and delivery_status='Failed'),delivery_unknown_count=(select count(*) from private.sms_cost_usage where flow_id=p_flow and delivery_status='Unknown'),acceptance_unknown_count=(select count(*) from private.sms_deliveries where flow_id=p_flow and status='Unknown' and provider_id is null and costing_rate is not null) where flow_id=p_flow;
$$;
create function private.sms_cost_record() returns trigger language plpgsql security definer set search_path='' as $$
declare a uuid;changed integer;
begin
 if new.costing_rate is null or new.flow_id is null or new.costing_quote_code is null then return new;end if;
 a:=private.attach_sms_cost(new.flow_id,case when exists(select 1 from public.quotes where id=new.costing_quote_id) then new.costing_quote_id end,new.costing_quote_code);
 if coalesce(new.provider_id,'')='' then perform private.refresh_sms_cost_delivery(new.flow_id);return new;end if;
 -- An AWS MessageId is the acceptance evidence, independent of handset outcome.
 insert into private.sms_cost_usage(notification_id,unit_id,flow_id,origin_quote_id,origin_quote_code,provider_id,accepted_at,unit_cost,delivery_status)
 values(new.notification_id,'10000000-0000-0000-0000-000000000002',new.flow_id,new.costing_quote_id,new.costing_quote_code,new.provider_id,coalesce(new.finished_at,now()),new.costing_rate,'Unknown') on conflict do nothing;
 get diagnostics changed=row_count;
 if changed=0 then perform private.refresh_sms_cost_delivery(new.flow_id);return new;end if;

 update public.sms_cost_totals set sms_count=sms_count+1,exact_cost=exact_cost+new.costing_rate,updated_at=now() where id=a;
 perform private.refresh_sms_cost_delivery(new.flow_id);perform private.try_post_sms_cost(a);return new;
end$$;
create trigger sms_cost_record after update of status,provider_id on private.sms_deliveries for each row execute function private.sms_cost_record();

create function private.sms_cost_job_lifecycle() returns trigger language plpgsql security definer set search_path='' as $$declare a uuid;
begin
 if new.unit_id<>'10000000-0000-0000-0000-000000000002' then return new;end if;
 if exists(select 1 from public.sms_cost_totals where flow_id=new.flow_id) then a:=private.attach_sms_cost(new.flow_id,new.quote_id,(select code from public.quotes where id=new.quote_id));perform private.try_post_sms_cost(a);end if;
 return new;
end$$;
create trigger sms_cost_job_lifecycle after insert or update of status,work_stage on public.jobs for each row execute function private.sms_cost_job_lifecycle();
create function private.sms_cost_quote_lifecycle() returns trigger language plpgsql security definer set search_path='' as $$declare a uuid;
begin
 if TG_OP='UPDATE' and new.status<>'Expired' then return new;end if;
 if old.unit_id<>'10000000-0000-0000-0000-000000000002' then return old;end if;
 select id into a from public.sms_cost_totals where flow_id=old.flow_id for update;
 if a is not null and not exists(select 1 from public.jobs where flow_id=old.flow_id) and not exists(select 1 from public.quotes where flow_id=old.flow_id and id<>old.id and status in ('Draft','Sent','Viewed','Agreement Pending','Accepted')) then
 update public.sms_cost_totals set quote_id=old.id,quote_code=old.code,closed_at=coalesce(closed_at,now()),close_reason=case when TG_OP='DELETE' then 'Quote deleted' else 'Quote expired' end,updated_at=now() where id=a;perform private.try_post_sms_cost(a);
 end if;
 if TG_OP='DELETE' then return old;end if;return new;
end$$;
create trigger sms_cost_quote_expired after update of status on public.quotes for each row execute function private.sms_cost_quote_lifecycle();
create trigger sms_cost_quote_deleted before delete on public.quotes for each row execute function private.sms_cost_quote_lifecycle();

-- Phase 1 stores outcomes; no CloudWatch reader/schedule is enabled.
-- A later trusted ingestion can annotate a known acceptance without changing its charge.
create function public.record_sms_delivery_outcome(p_provider text,p_status text,p_reason text default null,p_observed_at timestamptz default now()) returns boolean language plpgsql security definer set search_path='' as $$declare f uuid;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 if p_status not in ('Delivered','Failed') or p_status is null then raise exception 'Invalid delivery outcome';end if;
 select flow_id into f from private.sms_cost_usage where unit_id='10000000-0000-0000-0000-000000000002' and provider_id=p_provider;
 if f is null then return false;end if;perform 1 from public.sms_cost_totals where flow_id=f for update;
 update private.sms_cost_usage set delivery_status=p_status,delivery_reason=left(p_reason,500),delivery_observed_at=p_observed_at where unit_id='10000000-0000-0000-0000-000000000002' and provider_id=p_provider and (delivery_observed_at is null or delivery_observed_at<=p_observed_at) returning flow_id into f;
 if f is null then return false;end if;perform private.refresh_sms_cost_delivery(f);return true;
end$$;
revoke all on function public.record_sms_delivery_outcome(text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.record_sms_delivery_outcome(text,text,text,timestamptz) to service_role;
-- Accounting is decoupled from delivery confirmation: an accounting error cannot lose a sent SMS.
create function public.reconcile_sms_costs() returns void language plpgsql security definer set search_path='' as $$declare a record;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 for a in select id from public.sms_cost_totals where closed_at is not null and round(exact_cost,2)>posted_amount order by id loop
 begin perform private.post_sms_cost(a.id);exception when others then update public.sms_cost_totals set posting_error='Accounting posting failed; pending retry',updated_at=now() where id=a.id;end;
 end loop;
end$$;
revoke all on function public.reconcile_sms_costs() from public,anon,authenticated;
grant execute on function public.reconcile_sms_costs() to service_role;
-- Reuse the existing cron entry point; no extra schedule or production activation.
do $$declare d text;begin
 select pg_get_functiondef('public.run_scheduled_tasks()'::regprocedure) into d;
 if position('perform private.audit_cutoff_reminders();' in d)=0 then raise exception 'Unexpected scheduled task definition';end if;
 d:=replace(d,'perform private.audit_cutoff_reminders();','perform public.reconcile_sms_costs(); perform private.audit_cutoff_reminders();');execute d;
end$$;
create function public.save_sms_cost_settings(p_rate numeric,p_account uuid) returns void language plpgsql security definer set search_path='' as $$begin
 perform private.require_owner('10000000-0000-0000-0000-000000000002');
 if p_rate is null or p_rate<0 or p_rate>9999 or p_rate<>round(p_rate,8) then raise exception 'Use a nonnegative SMS cost with up to eight decimal places';end if;
 if not exists(select 1 from public.accounts where id=p_account and unit_id='10000000-0000-0000-0000-000000000002' and active) then raise exception 'Choose an active ToolTag SMS expense account';end if;
 update public.unit_settings set sms_unit_cost=p_rate,sms_expense_account_id=p_account where unit_id='10000000-0000-0000-0000-000000000002';
 perform private.rbac_log('settings.sms_cost.saved',p_account,jsonb_build_object('unit_cost',p_rate));
end$$;
revoke all on function public.save_sms_cost_settings(numeric,uuid) from public,anon;
grant execute on function public.save_sms_cost_settings(numeric,uuid) to authenticated;
revoke all on function private.post_sms_cost(uuid),private.try_post_sms_cost(uuid),private.attach_sms_cost(uuid,uuid,text),private.sms_cost_prepare(),private.sms_cost_record(),private.refresh_sms_cost_delivery(uuid),private.sms_cost_job_lifecycle(),private.sms_cost_quote_lifecycle() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
