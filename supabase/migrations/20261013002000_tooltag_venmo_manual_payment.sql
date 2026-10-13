-- Local batch only: confirmed ToolTag payee; existing manual verification unchanged.
begin;
update public.unit_settings set venmo_handle='@boftbuild'
where unit_id='10000000-0000-0000-0000-000000000002';
commit;
