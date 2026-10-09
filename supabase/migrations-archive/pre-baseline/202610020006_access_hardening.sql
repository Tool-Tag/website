-- Override hosted Supabase default privileges explicitly; never depend on project defaults.
do $$ declare r record; begin
 for r in select tablename as name from pg_tables where schemaname='public' loop
 execute format('revoke all on public.%I from anon, authenticated',r.name);
 execute format('grant select on public.%I to authenticated',r.name);
 end loop;
 for r in select viewname as name from pg_views where schemaname='public' loop
 execute format('revoke all on public.%I from anon, authenticated',r.name);
 execute format('grant select on public.%I to authenticated',r.name);
 end loop;
end $$;
revoke all on all tables in schema private from anon,authenticated;
revoke all on all sequences in schema private from anon,authenticated;
-- All new functions must be explicitly exposed in a versioned migration.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema private revoke execute on functions from public;
