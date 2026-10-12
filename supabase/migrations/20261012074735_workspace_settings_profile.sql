-- Phase C: optional workspace profile and route departure reference. Forward-only.
-- No production application until audit/rollout approval. No Agreement or BOFT changes.
begin;
alter table public.unit_settings
 add column business_display_name text check(length(business_display_name)<=160),
 add column business_contact_email text check(length(business_contact_email)<=254),
 add column business_contact_phone text check(length(business_contact_phone)<=40),
 add column route_departure_address text check(length(route_departure_address)<=1000);
comment on column public.unit_settings.route_departure_address is 'Driver departure reference; live ETA remains based on current driver GPS. Does not change scheduling or existing bookings.';
create function public.save_workspace_profile(p jsonb) returns void language plpgsql security definer set search_path='' as $$
declare u uuid:='10000000-0000-0000-0000-000000000002';k text;v text;
begin
 perform private.require_owner(u);
 if (p ? 'unit_id') and (p->>'unit_id')::uuid is distinct from u then raise exception 'ToolTag workspace only' using errcode='42501';end if;
 foreach k in array array['business_display_name','business_contact_email','business_contact_phone','route_departure_address'] loop
 if p ? k and jsonb_typeof(p->k) not in ('string','null') then raise exception 'Invalid workspace field: %',k;end if;
 end loop;
 v:=nullif(trim(p->>'business_contact_email'),'');
 if v is not null and v !~* '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+[.][^[:space:]<>@,;]+$' then raise exception 'Enter a valid business email';end if;
 update public.unit_settings set
 business_display_name=case when p ? 'business_display_name' then nullif(trim(p->>'business_display_name'),'') else business_display_name end,
 business_contact_email=case when p ? 'business_contact_email' then lower(v) else business_contact_email end,
 business_contact_phone=case when p ? 'business_contact_phone' then nullif(trim(p->>'business_contact_phone'),'') else business_contact_phone end,
 route_departure_address=case when p ? 'route_departure_address' then nullif(trim(p->>'route_departure_address'),'') else route_departure_address end
 where unit_id=u;
 if not found then raise exception 'ToolTag workspace settings unavailable';end if;
 perform private.rbac_log('settings.profile.saved',u,jsonb_build_object('fields',array(select key from jsonb_object_keys(p) key where key in ('business_display_name','business_contact_email','business_contact_phone','route_departure_address'))));
end$$;
revoke all on function public.save_workspace_profile(jsonb) from public,anon;
grant execute on function public.save_workspace_profile(jsonb) to authenticated;
commit;
