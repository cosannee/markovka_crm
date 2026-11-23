-- Split the former shared Ozon account into Dasha and Sasha accounts.
-- The existing balance stays with Dasha; Sasha starts at zero.
begin;

update public.finance
set data=(data||jsonb_build_object('name','Озон Банк Даша','owner','dasha'))
where data->>'kind'='account'
  and lower(btrim(data->>'name'))='озон банк'
  and coalesce(data->>'archived','false')<>'true';

update public.finance
set data=data||jsonb_build_object('owner','dasha')
where data->>'kind'='account' and lower(btrim(data->>'name'))='озон банк даша';

update public.finance
set data=data||jsonb_build_object('owner','sasha')
where data->>'kind'='account' and lower(btrim(data->>'name'))='озон банк саша';

insert into public.finance(id,data)
select 'account_ozon_dasha',jsonb_build_object(
  'id','account_ozon_dasha','kind','account','name','Озон Банк Даша','type','bank',
  'owner','dasha','startBalance',0,'startDate',to_char(current_date,'YYYY-MM-DD'),
  'ord',0,'archived',false,'created',floor(extract(epoch from clock_timestamp())*1000)::bigint
)
where not exists (
  select 1 from public.finance where data->>'kind'='account'
    and lower(btrim(data->>'name'))='озон банк даша' and coalesce(data->>'archived','false')<>'true'
);

insert into public.finance(id,data)
select 'account_ozon_sasha',jsonb_build_object(
  'id','account_ozon_sasha','kind','account','name','Озон Банк Саша','type','bank',
  'owner','sasha','startBalance',0,'startDate',to_char(current_date,'YYYY-MM-DD'),
  'ord',coalesce((select max(crm_private.fin_num(data,'ord'))+1 from public.finance where data->>'kind'='account'),1),
  'archived',false,'created',floor(extract(epoch from clock_timestamp())*1000)::bigint
)
where not exists (
  select 1 from public.finance where data->>'kind'='account'
    and lower(btrim(data->>'name'))='озон банк саша' and coalesce(data->>'archived','false')<>'true'
);

create or replace function crm_private.guard_director_bank_account() returns trigger
language plpgsql security definer set search_path='' as $$
declare p public.crm_profiles; row_data jsonb; account_data jsonb;
begin
  p:=crm_private.profile();
  if p.user_id is null or p.role<>'director' then return case when tg_op='DELETE' then old else new end;end if;
  row_data:=case when tg_op='DELETE' then old.data else new.data end;
  if tg_op='DELETE' and row_data->>'kind' in ('account','tx') then
    raise exception 'Удалять счета и банковские операции может только Саша' using errcode='42501';
  end if;
  if row_data->>'kind'='account' then
    raise exception 'Настройки счетов доступны только Саше' using errcode='42501';
  end if;
  if row_data->>'kind'='tx' then
    if row_data->>'type'='transfer' then
      raise exception 'Переводы между счетами доступны только Саше' using errcode='42501';
    end if;
    select data into account_data from public.finance where id=row_data->>'accountId';
    if account_data is null or not (
      account_data->>'owner'='dasha'
      or lower(btrim(account_data->>'name')) in ('озон банк','озон банк даша')
    ) then
      raise exception 'Даше доступен только счёт «Озон Банк Даша»' using errcode='42501';
    end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;

drop trigger if exists crm_guard_director_bank_account on public.finance;
create trigger crm_guard_director_bank_account
before insert or update or delete on public.finance
for each row execute function crm_private.guard_director_bank_account();

revoke all on function crm_private.guard_director_bank_account() from public,anon,authenticated;
commit;
