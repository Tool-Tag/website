-- Phase B: isolated Support/Hello inbox. No changes to applied RBAC or customer mail.
begin;
create table public.support_conversations (
 id uuid primary key default gen_random_uuid(),
 unit_id uuid not null references public.business_units(id),
 mailbox text not null check(mailbox in ('support','hello')),
 sender_email text not null, sender_name text not null default '', subject text not null,
 customer_id uuid references public.customers(id),
 case_code text unique, status text not null default 'New' check(status in ('New','Open','Closed')),
 unread_count integer not null default 1 check(unread_count>=0),
 updated_at timestamptz not null default now(), created_at timestamptz not null default now(), closed_at timestamptz,
 unique(id,unit_id)
);
create table public.support_threads (
 gmail_thread_id text not null, mailbox text not null check(mailbox in ('support','hello')),
 conversation_id uuid not null references public.support_conversations(id),
 primary key(gmail_thread_id,mailbox)
);
create table public.support_messages (
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.support_conversations(id),
 gmail_message_id text unique, gmail_thread_id text, rfc_message_id text not null default '',
 references_header text not null default '', in_reply_to text not null default '',
 direction text not null check(direction in ('Inbound','Outbound')),
 sender_email text not null, subject text not null, body text not null,
 sent_at timestamptz not null default now(), actor_id uuid references auth.users(id),
 delivery_status text not null default 'Received' check(delivery_status in ('Received','Sending','Sent','Failed','Unknown')),
 delivery_error text, unique(conversation_id,id)
);
create index support_conversation_tabs on public.support_conversations(unit_id,status,mailbox,updated_at desc);
create index support_message_conversation on public.support_messages(conversation_id,sent_at);
create index support_rfc_lookup on public.support_messages(rfc_message_id);
create table private.support_case_counter(year integer primary key, value integer not null);
create table private.support_sync_state(
 id boolean primary key default true check(id), since_at timestamptz not null default now()-interval '5 minutes',
 page_token text, scan_since timestamptz, scan_started timestamptz,
 lease uuid, lease_until timestamptz, last_error text, last_success timestamptz
);
insert into private.support_sync_state(id) values(true);
alter table public.support_conversations enable row level security;
alter table public.support_threads enable row level security;
alter table public.support_messages enable row level security;
alter table private.support_case_counter enable row level security;
alter table private.support_sync_state enable row level security;
revoke all on public.support_conversations,public.support_threads,public.support_messages from public,anon,authenticated;
grant select on public.support_conversations,public.support_threads,public.support_messages to authenticated;
create policy support_read on public.support_conversations for select to authenticated using(private.has_block(unit_id,'support.inbox'));
create policy support_threads_read on public.support_threads for select to authenticated using(exists(select 1 from public.support_conversations c where c.id=conversation_id));
create policy support_messages_read on public.support_messages for select to authenticated using(exists(select 1 from public.support_conversations c where c.id=conversation_id));
create function private.require_support() returns void language plpgsql security definer set search_path='' as $$begin
 if not private.has_block('10000000-0000-0000-0000-000000000002','support.inbox') then raise exception 'Support inbox permission required' using errcode='42501';end if;
end$$;
create function private.require_support_worker() returns void language plpgsql security definer set search_path='' as $$begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required' using errcode='42501';end if;
end$$;
create function public.support_begin_sync() returns jsonb language plpgsql security definer set search_path='' as $$declare s private.support_sync_state;begin
 perform private.require_support_worker();select * into s from private.support_sync_state where id for update;
 if s.lease_until>now() then return null;end if;
 update private.support_sync_state set lease=gen_random_uuid(),lease_until=now()+interval '6 minutes',scan_since=coalesce(scan_since,since_at-interval '5 minutes'),scan_started=coalesce(scan_started,now()) where id returning * into s;
 return jsonb_build_object('lease',s.lease,'since',s.scan_since,'before',s.scan_started,'page_token',s.page_token);
end$$;
create function public.support_finish_sync(p_lease uuid,p_next text,p_error text default null) returns void language plpgsql security definer set search_path='' as $$begin
 perform private.require_support_worker();
 update private.support_sync_state set
 since_at=case when p_error is null and p_next is null then scan_started else since_at end,
 page_token=case when p_error='GMAIL_REJECTED_400' then null when p_error is null then p_next else page_token end,
 scan_since=case when p_error is null and p_next is null then null else scan_since end,
 scan_started=case when p_error is null and p_next is null then null else scan_started end,
 last_success=case when p_error is null then now() else last_success end,
 last_error=left(p_error,100),lease=null,lease_until=null where id and lease=p_lease;
end$$;
create function public.support_ingest(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$declare c public.support_conversations;cid uuid;u uuid:='10000000-0000-0000-0000-000000000002';matches integer;code text;begin
 perform private.require_support_worker();
 if p->>'mailbox' not in ('support','hello') or length(coalesce(p->>'sender_email',''))=0 or length(coalesce(p->>'gmail_message_id',''))=0 or length(coalesce(p->>'gmail_thread_id',''))=0 then raise exception 'Invalid incoming Support message';end if;
 perform pg_advisory_xact_lock(hashtext('tooltag-support-ingest'));
 if exists(select 1 from public.support_messages where gmail_message_id=p->>'gmail_message_id') then return (select conversation_id from public.support_messages where gmail_message_id=p->>'gmail_message_id');end if;
 select cc.* into c from public.support_threads t join public.support_conversations cc on cc.id=t.conversation_id where t.gmail_thread_id=p->>'gmail_thread_id' and t.mailbox=p->>'mailbox';
 -- Fallbacks require the same sender and department; a guessed folio cannot attach another customer's mail.
 if c.id is null then
 code:=substring(p->>'subject' from 'TT-C-[0-9]{4}-[0-9]{5,}');
 select * into c from public.support_conversations where unit_id=u and mailbox=p->>'mailbox' and lower(sender_email)=lower(p->>'sender_email') and case_code=code;
 end if;
 if c.id is null then
 select cc.* into c from public.support_messages m join public.support_conversations cc on cc.id=m.conversation_id where cc.unit_id=u and cc.mailbox=p->>'mailbox' and lower(cc.sender_email)=lower(p->>'sender_email') and m.rfc_message_id<>'' and (m.rfc_message_id=p->>'in_reply_to' or position(m.rfc_message_id in coalesce(p->>'references_header',''))>0) order by m.sent_at desc limit 1;
 end if;
 if c.id is null then
 select count(*),(array_agg(id))[1] into matches,cid from public.customers where unit_id=u and (lower(email)=lower(p->>'sender_email') or lower(company_email)=lower(p->>'sender_email'));
 insert into public.support_conversations(unit_id,mailbox,sender_email,sender_name,subject,customer_id,unread_count) values(u,p->>'mailbox',lower(p->>'sender_email'),left(coalesce(p->>'sender_name',''),200),left(coalesce(p->>'subject','(No subject)'),500),case when matches=1 then cid else null end,0) returning * into c;
 end if;
 insert into public.support_threads values(p->>'gmail_thread_id',p->>'mailbox',c.id) on conflict do nothing;
 insert into public.support_messages(conversation_id,gmail_message_id,gmail_thread_id,rfc_message_id,references_header,in_reply_to,direction,sender_email,subject,body,sent_at)
 values(c.id,p->>'gmail_message_id',p->>'gmail_thread_id',left(coalesce(p->>'rfc_message_id',''),1000),left(coalesce(p->>'references_header',''),5000),left(coalesce(p->>'in_reply_to',''),1000),'Inbound',lower(p->>'sender_email'),left(coalesce(p->>'subject',''),500),left(coalesce(p->>'body',''),100000),(p->>'sent_at')::timestamptz);
 update public.support_conversations set unread_count=unread_count+1,status=case when status='Closed' then 'Open' else status end,closed_at=null,updated_at=greatest(updated_at,(p->>'sent_at')::timestamptz) where id=c.id;
 return c.id;
end$$;
create function public.support_mark_read(p_id uuid,p_through timestamptz) returns void language plpgsql security definer set search_path='' as $$begin
 perform private.require_support();
 perform 1 from public.support_conversations where id=p_id and unit_id='10000000-0000-0000-0000-000000000002' for update;
 update public.support_conversations c set unread_count=(select count(*) from public.support_messages m where m.conversation_id=c.id and direction='Inbound' and sent_at>p_through) where c.id=p_id and c.unit_id='10000000-0000-0000-0000-000000000002';
end$$;
create function public.support_close(p_id uuid) returns void language plpgsql security definer set search_path='' as $$begin
 perform private.require_support();
 perform 1 from public.support_conversations where id=p_id and unit_id='10000000-0000-0000-0000-000000000002' for update;
 if exists(select 1 from public.support_messages where conversation_id=p_id and delivery_status in ('Sending','Unknown')) then raise exception 'Resolve the pending reply before closing this case';end if;
 if exists(select 1 from public.support_conversations where id=p_id and unread_count>0) then raise exception 'Read the latest incoming response before closing this case';end if;
 update public.support_conversations set status='Closed',closed_at=now(),unread_count=0 where id=p_id and unit_id='10000000-0000-0000-0000-000000000002' and case_code is not null;
 if not found then raise exception 'Only a replied case can be closed';end if;
 perform private.rbac_log('support.case.closed',p_id);
end$$;
create function public.support_prepare_reply(p_id uuid,p_request uuid,p_body text) returns jsonb language plpgsql security definer set search_path='' as $$declare c public.support_conversations;m public.support_messages;n integer;y integer;signature text;out_id uuid;begin
 perform private.require_support();
 select * into c from public.support_conversations where id=p_id and unit_id='10000000-0000-0000-0000-000000000002' for update;
 if c.id is null or length(trim(p_body)) not between 1 and 20000 then raise exception 'A reply of 1–20000 characters is required';end if;
 if exists(select 1 from public.support_messages where id=p_request) then raise exception 'Reply already submitted; refresh to see its delivery status';end if;
 if exists(select 1 from public.support_messages where conversation_id=c.id and delivery_status in ('Sending','Unknown')) then raise exception 'A reply is pending verification; do not resend';end if;
 select * into m from public.support_messages where conversation_id=c.id and direction='Inbound' order by sent_at desc,id desc limit 1;
 if m.id is null then raise exception 'Incoming message unavailable';end if;
 if c.case_code is null then
 y:=extract(year from now() at time zone 'America/Denver');
 insert into private.support_case_counter values(y,1) on conflict(year) do update set value=support_case_counter.value+1 returning value into n;
 update public.support_conversations set case_code='TT-C-'||y||'-'||lpad(n::text,greatest(5,length(n::text)),'0') where id=c.id returning * into c;
 end if;
 select coalesce(nullif(display_name,''),'ToolTag Team') into signature from public.staff_access where unit_id=c.unit_id and user_id=auth.uid();
 insert into public.support_messages(id,conversation_id,rfc_message_id,gmail_thread_id,direction,sender_email,subject,body,actor_id,delivery_status)
 values(p_request,c.id,'<'||p_request||'@tooltag.martinlab.studio>',m.gmail_thread_id,'Outbound',c.mailbox,'['||c.case_code||'] Re: '||regexp_replace(c.subject,'^(Re: *)+','','i'),trim(p_body)||E'\n\n'||signature||E'\nToolTag',auth.uid(),'Sending') returning id into out_id;
 perform private.rbac_log('support.reply.prepared',c.id,jsonb_build_object('reply_id',out_id));
 return jsonb_build_object('id',out_id,'case_code',c.case_code,'mailbox',c.mailbox,'to',c.sender_email,'thread_id',m.gmail_thread_id,'in_reply_to',m.rfc_message_id,'references',trim(m.references_header||' '||m.rfc_message_id),'message_id','<'||out_id||'@tooltag.martinlab.studio>','subject','['||c.case_code||'] Re: '||regexp_replace(c.subject,'^(Re: *)+','','i'),'body',trim(p_body)||E'\n\n'||signature||E'\nToolTag');
end$$;
create function public.support_finish_reply(p_id uuid,p_status text,p_gmail_id text default null,p_thread text default null,p_error text default null) returns void language plpgsql security definer set search_path='' as $$declare m public.support_messages;c public.support_conversations;begin
 perform private.require_support_worker();
 if p_status not in ('Sent','Failed','Unknown') or (p_status='Sent' and (coalesce(p_gmail_id,'')='' or coalesce(p_thread,'')='')) then raise exception 'Invalid reply result';end if;
 select * into m from public.support_messages where id=p_id and direction='Outbound' for update;
 if m.id is null or m.delivery_status='Sent' then return;end if;
 update public.support_messages set delivery_status=p_status,gmail_message_id=p_gmail_id,gmail_thread_id=coalesce(p_thread,gmail_thread_id),delivery_error=left(p_error,100) where id=p_id;
 if p_status='Sent' then
 select * into c from public.support_conversations where id=m.conversation_id for update;
 insert into public.support_threads values(p_thread,c.mailbox,c.id) on conflict do nothing;
 update public.support_conversations set status='Open',closed_at=null,updated_at=now() where id=c.id;
 end if;
end$$;
create function public.support_attention() returns bigint language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_block('10000000-0000-0000-0000-000000000002','support.inbox') then return 0;end if;
 return (select count(*) from public.support_conversations where unit_id='10000000-0000-0000-0000-000000000002' and (status='New' or unread_count>0));
end$$;
create function public.support_integration_status() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform private.require_support();return (select jsonb_build_object('last_success',last_success,'last_error',last_error) from private.support_sync_state where id);
end$$;
revoke all on function private.require_support(),private.require_support_worker() from public,anon,authenticated;
revoke all on function public.support_begin_sync(),public.support_finish_sync(uuid,text,text),public.support_ingest(jsonb),public.support_finish_reply(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.support_begin_sync(),public.support_finish_sync(uuid,text,text),public.support_ingest(jsonb),public.support_finish_reply(uuid,text,text,text,text) to service_role;
revoke all on function public.support_mark_read(uuid,timestamptz),public.support_close(uuid),public.support_prepare_reply(uuid,uuid,text),public.support_attention(),public.support_integration_status() from public,anon;
grant execute on function public.support_mark_read(uuid,timestamptz),public.support_close(uuid),public.support_prepare_reply(uuid,uuid,text),public.support_attention(),public.support_integration_status() to authenticated;
grant select on public.support_messages,public.support_threads,public.support_conversations to service_role;
commit;
