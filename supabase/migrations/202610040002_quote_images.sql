-- Private original assets. Removing a draft reference never deletes accepted evidence.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('quote-images','quote-images',false,3145728,array['image/png','image/jpeg','image/webp']) on conflict(id) do nothing;
create policy quote_images_read on storage.objects for select to authenticated using(
 bucket_id='quote-images' and (storage.foldername(name))[1]='10000000-0000-0000-0000-000000000002'
 and exists(select 1 from public.memberships where user_id=auth.uid() and unit_id='10000000-0000-0000-0000-000000000002'));
create policy quote_images_insert on storage.objects for insert to authenticated with check(
 bucket_id='quote-images' and (storage.foldername(name))[1]='10000000-0000-0000-0000-000000000002'
 and exists(select 1 from public.memberships where user_id=auth.uid() and unit_id='10000000-0000-0000-0000-000000000002' and role='admin'));
