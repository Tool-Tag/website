-- Network retries must not register the same payment/expense twice.
create table private.mutation_requests (
 unit_id uuid not null references public.business_units,
 request_id uuid not null, payload_hash text not null,
 transaction_id uuid not null references public.transactions,
 primary key(unit_id,request_id)
);
alter function public.record_movement(jsonb) set schema private;
revoke all on function private.record_movement(jsonb) from public,anon,authenticated;
create function public.record_movement(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=(p->>'unit_id')::uuid; key uuid:=coalesce(nullif(p->>'request_id','')::uuid,gen_random_uuid());
 fingerprint text:=encode(sha256(convert_to((p-'request_id')::text,'UTF8')),'hex'); prior private.mutation_requests; tid uuid;
begin
 perform private.require_admin(u);
 perform 1 from public.business_units where id=u for update;
 select * into prior from private.mutation_requests where unit_id=u and request_id=key;
 if found then
 if prior.payload_hash<>fingerprint then raise exception 'This request identifier was already used for different information'; end if;
 return prior.transaction_id;
 end if;
 tid:=private.record_movement(p);
 insert into private.mutation_requests values(u,key,fingerprint,tid);
 return tid;
end $$;
grant execute on function public.record_movement(jsonb) to authenticated;
create function private.queue_commercial_events() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='quotes' then
 if NEW.status='Agreement Pending' and OLD.status<>NEW.status then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(NEW.unit_id,'Agreement acceptance request',NEW.id,'agreement-request:'||NEW.id) on conflict do nothing;
 end if;
 if NEW.status='Sent' and NEW.revision>1 and OLD.status<>NEW.status then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(NEW.unit_id,'Revision requires acceptance',NEW.id,'revision:'||NEW.id) on conflict do nothing;
 end if;
 elsif TG_TABLE_NAME='jobs' and NEW.status in ('Completed','Issue / Review') and OLD.status<>NEW.status then
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
 values(NEW.unit_id,case when NEW.status='Completed' then 'Final completion' else 'Customer reported issue' end,NEW.id,'job-final:'||NEW.id||':'||NEW.status,jsonb_build_object('reason',NEW.completion_reason)) on conflict do nothing;
 end if;
 return NEW;
end $$;
create trigger quote_events after update on public.quotes for each row execute function private.queue_commercial_events();
create trigger completion_events after update on public.jobs for each row execute function private.queue_commercial_events();
