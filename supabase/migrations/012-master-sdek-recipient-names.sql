-- Give each master only the recipient names needed to verify their own
-- shipments in the dedicated SDEK section. No phone, address, or other
-- customer fields are returned.
begin;

create or replace function public.crm_master_sdek_recipients()
returns table(order_id text, client_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p public.crm_profiles;
begin
  p := crm_private.profile();
  if p.user_id is null or p.role <> 'master' then
    raise exception 'Access denied' using errcode = '42501';
  end if;

  return query
    select o.id::text, coalesce(o.data->>'client', '')
    from public.orders as o
    where o.data->>'master' = p.master_name
      and o.data->>'status' = 'planned'
    order by o.id::text;
end;
$$;

revoke all on function public.crm_master_sdek_recipients() from public, anon;
grant execute on function public.crm_master_sdek_recipients() to authenticated;

commit;
