-- Disabled by default at the application boundary. No SMS or customer changes on migration.
create table private.phone_verifications (
 id uuid primary key, phone text not null check(phone ~ '^\+[1-9][0-9]{7,14}$'),
 session_hash text not null, code_hash text not null, network_hash text not null,
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '10 minutes',
 attempts integer not null default 0, delivery text not null default 'Pending' check(delivery in ('Pending','Sent','Failed')),
 verified_at timestamptz
);
create index phone_verification_rate on private.phone_verifications(phone,created_at);
create index phone_verification_network_rate on private.phone_verifications(network_hash,created_at);
alter table private.phone_verifications enable row level security;
revoke all on private.phone_verifications from public,anon,authenticated;
create function public.begin_phone_verification(p_id uuid,p_phone text,p_session text,p_code text,p_network text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Server credentials required';end if;
 perform pg_advisory_xact_lock(hashtextextended('tooltag-phone-verification',0));
 if p_session !~ '^[a-f0-9]{64}$' or p_code !~ '^[a-f0-9]{64}$' or p_network !~ '^[a-f0-9]{64}$' then raise exception 'Invalid verification';end if;
 if exists(select 1 from private.phone_verifications where phone=p_phone and created_at>now()-interval '60 seconds') then raise exception 'Wait 60 seconds before requesting another code';end if;
 if (select count(*) from private.phone_verifications where phone=p_phone and created_at>now()-interval '1 hour')>=5 or
 (select count(*) from private.phone_verifications where network_hash=p_network and created_at>now()-interval '1 hour')>=20 or
 (select count(*) from private.phone_verifications where created_at>now()-interval '1 hour')>=100 then raise exception 'Verification rate limit';end if;
 insert into private.phone_verifications(id,phone,session_hash,code_hash,network_hash) values(p_id,p_phone,p_session,p_code,p_network);
end $$;
create function public.phone_verification_result(p_id uuid,p_delivery text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Server credentials required';end if;
 if p_delivery not in ('Sent','Failed') then raise exception 'Invalid delivery';end if;
 update private.phone_verifications set delivery=p_delivery where id=p_id and delivery='Pending';
end $$;
create function public.check_phone_verification(p_id uuid,p_session text,p_code text) returns boolean
language plpgsql security definer set search_path='' as $$
declare v private.phone_verifications;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Server credentials required';end if;
 select * into v from private.phone_verifications where id=p_id for update;
 if v.id is null or v.session_hash<>p_session or v.expires_at<=now() or v.delivery<>'Sent' or v.attempts>=5 then return false;end if;
 if v.verified_at is not null then return true;end if;
 update private.phone_verifications set attempts=attempts+1,verified_at=case when code_hash=p_code then now() else null end where id=p_id;
 return v.code_hash=p_code;
end $$;
create function public.phone_verification_valid(p_id uuid,p_session text,p_phone text) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Server credentials required';end if;
 return exists(select 1 from private.phone_verifications where id=p_id and session_hash=p_session and phone=p_phone and delivery='Sent' and verified_at is not null and expires_at>now());
end $$;
revoke all on function public.begin_phone_verification(uuid,text,text,text,text),public.phone_verification_result(uuid,text),public.check_phone_verification(uuid,text,text),public.phone_verification_valid(uuid,text,text) from public,anon,authenticated;
grant execute on function public.begin_phone_verification(uuid,text,text,text,text),public.phone_verification_result(uuid,text),public.check_phone_verification(uuid,text,text),public.phone_verification_valid(uuid,text,text) to service_role;
