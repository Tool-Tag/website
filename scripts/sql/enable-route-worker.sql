-- Run once AFTER the matching app deployment and migration are active.
-- Store tooltag_worker_url (the deployed /api/cron URL) and
-- tooltag_worker_secret (the same CRON_SECRET as Vercel) in Vault first.
-- No credentials belong in this file.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
select cron.schedule('tooltag-route-worker','*/5 * * * *', $worker$
 select net.http_get(
  url := (select decrypted_secret from vault.decrypted_secrets where name='tooltag_worker_url'),
  headers := jsonb_build_object('Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='tooltag_worker_secret')),
  timeout_milliseconds := 300000
 );
$worker$);
