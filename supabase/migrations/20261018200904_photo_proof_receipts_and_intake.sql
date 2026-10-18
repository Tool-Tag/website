begin;
alter table public.lost_jobs add column missing_receipt boolean not null default false;
create function private.mark_lost_missing_receipt() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.replacement_expense_id is not null then
  new.missing_receipt:=not exists(select 1 from public.documents d where d.transaction_id=new.replacement_expense_id and d.type='Receipt' and d.storage_status='stored' and d.status='Available');
 end if;
 return new;
end$$;
create trigger lost_receipt_mark before insert or update of replacement_expense_id on public.lost_jobs for each row execute function private.mark_lost_missing_receipt();
do $$declare d text;begin
 d:=pg_get_functiondef('public.lost_job_list()'::regprocedure);
 if position('''id'',l.id' in d)=0 then raise exception 'Unexpected Lost list definition';end if;
 d:=replace(d,'''id'',l.id','''missing_receipt'',l.missing_receipt,''id'',l.id');execute d;
 d:=pg_get_viewdef('public.expense_details'::regclass,true);
 d:=replace(d,' AND (NOT e.lodging)','');
 d:=replace(d,'''Receipt Not Required (<$75)''::text','case when exists(select 1 from public.lost_jobs lost where lost.replacement_expense_id=t.id and lost.missing_receipt) then ''Missing Receipt''::text else ''Receipt Not Required (<$75)''::text end');
 execute 'create or replace view public.expense_details with(security_invoker=true) as '||d;
end$$;
-- Private storage metadata, writable only by the trusted intake endpoint.
create table public.get_tagged_tool_photos(
 id uuid primary key, request_key uuid not null, network text not null,
 storage_path text not null unique, mime_type text not null check(mime_type in ('image/png','image/jpeg','image/webp')),
 file_size integer not null check(file_size between 1 and 3145728),
 stored boolean not null default false, created_at timestamptz not null default now()
);
alter table public.get_tagged_tool_photos enable row level security;
revoke all on public.get_tagged_tool_photos from public,anon,authenticated;
grant select,insert,update,delete on public.get_tagged_tool_photos to service_role;
create index get_tagged_tool_photos_rate on public.get_tagged_tool_photos(network,created_at);
create index get_tagged_tool_photos_request on public.get_tagged_tool_photos(request_key);
create function public.reserve_intake_photo(p_id uuid,p_key uuid,p_network text,p_mime text,p_size integer) returns text
language plpgsql security definer set search_path='' as $$
declare path text;begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Server credentials required' using errcode='42501';end if;
 if p_network is null or length(p_network)<>64 then raise exception 'Invalid upload request';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_network,0));
 if (select count(*) from public.get_tagged_tool_photos where network=p_network and created_at>now()-interval '1 day')>=100 or (select count(*) from public.get_tagged_tool_photos where request_key=p_key)>=20 then raise exception 'Photo upload limit reached';end if;
 path:='10000000-0000-0000-0000-000000000002/intake/'||p_key||'/'||p_id;
 insert into public.get_tagged_tool_photos(id,request_key,network,storage_path,mime_type,file_size) values(p_id,p_key,p_network,path,p_mime,p_size);
 return path;
end$$;
revoke all on function public.reserve_intake_photo(uuid,uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.reserve_intake_photo(uuid,uuid,text,text,integer) to service_role;
notify pgrst,'reload schema';
commit;
