-- Atomic payout for assigned extra work. Extra work is stored as a task row;
-- this RPC records one bank expense and marks its task paid in the same transaction.
begin;

create table if not exists crm_private.extra_work_commands (
  id text primary key,
  actor uuid not null,
  request jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table crm_private.extra_work_commands enable row level security;
revoke all on crm_private.extra_work_commands from public, anon, authenticated;

create or replace function public.crm_extra_work_payout(p_id text, p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p public.crm_profiles;
  prior crm_private.extra_work_commands;
  t public.tasks;
  a public.finance;
  task_data jsonb;
  expected jsonb;
  tx jsonb;
  result jsonb;
  base_result jsonb;
  base_id text;
  item jsonb;
  ids text[] := '{}';
  changed jsonb := '[]'::jsonb;
  changed_tasks jsonb := '[]'::jsonb;
  changed_orders jsonb := '[]'::jsonb;
  lines jsonb := '[]'::jsonb;
  total numeric := 0;
  base_cash numeric := 0;
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  txid text;
  task_id text;
  recipient text;
  acc_id text;
  action_date text;
begin
  p := crm_private.profile();
  if p.user_id is null or p.role not in ('manager','director') then
    raise exception 'Нет доступа' using errcode='42501';
  end if;
  if p_id is null or length(p_id)<16 or length(p_id)>100 or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'Неверный запрос';
  end if;
  perform pg_advisory_xact_lock(27112026, 13);
  select * into prior from crm_private.extra_work_commands where id=p_id;
  if found then
    if prior.actor<>p.user_id or prior.request<>p_payload then raise exception 'Номер операции уже использован'; end if;
    select coalesce(jsonb_agg(f.data),'[]'::jsonb) into changed
      from public.finance f where f.id in (select value->>'id' from jsonb_array_elements(prior.result->'finance'));
    select coalesce(jsonb_agg(t.data),'[]'::jsonb) into changed_tasks
      from public.tasks t where t.id in (select value->>'id' from jsonb_array_elements(prior.result->'tasks'));
    select coalesce(jsonb_agg(o.data),'[]'::jsonb) into changed_orders
      from public.orders o where o.id in (select value->>'id' from jsonb_array_elements(prior.result->'orders'));
    return prior.result || jsonb_build_object('finance',changed,'tasks',changed_tasks,'orders',changed_orders);
  end if;
  if jsonb_typeof(p_payload->'tasks') is distinct from 'array'
     then raise exception 'Выберите задания для выплаты';
  end if;
  if jsonb_array_length(p_payload->'tasks') not between 1 and 100 then
    raise exception 'Выберите задания для выплаты';
  end if;
  recipient:=btrim(coalesce(p_payload->>'recipient',''));
  acc_id:=p_payload->>'accountId';
  action_date:=coalesce(nullif(p_payload->>'date',''),to_char(now() at time zone 'Europe/Moscow','YYYY-MM-DD'));
  if recipient='' or action_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Проверьте получателя и дату'; end if;
  perform action_date::date;
  select * into a from public.finance where id=acc_id for update;
  if a.data is null or a.data->>'kind'<>'account' or a.data->>'archived'='true' or a.data->>'type' in ('savings','debt') then
    raise exception 'Выберите действующий расчётный счёт';
  end if;
  txid:='xw_'||p_id;
  for item in select value from jsonb_array_elements(p_payload->'tasks') loop
    task_id:=item->>'id'; expected:=item->'expected';
    if task_id is null or task_id=any(ids) then raise exception 'Повтор задания в выплате'; end if;
    ids:=array_append(ids,task_id);
    select * into t from public.tasks where id=task_id for update;
    task_data:=t.data;
    if task_data is null or task_data->>'kind'<>'extra_work' or task_data->>'to' is distinct from recipient
       or task_data->>'done'='true' or expected is distinct from task_data then
      raise exception 'Задание изменилось или уже выплачено. Обновите список';
    end if;
    if crm_private.fin_num(task_data,'amount')<=0 then raise exception 'У задания некорректная сумма'; end if;
    total:=total+crm_private.fin_num(task_data,'amount');
    lines:=lines||jsonb_build_array(jsonb_build_object('type','extra_work','taskId',task_id,
      'orderId',task_data->>'orderId','orderNum',task_data->>'orderNum','description',task_data->>'text',
      'master',recipient,'amount',crm_private.fin_num(task_data,'amount')));
    task_data:=task_data||jsonb_build_object('done',true,'paidAt',ms,'payoutTxId',txid,'paidBy',p.name);
    update public.tasks set data=task_data where id=task_id;
    changed:=changed||jsonb_build_array(task_data);
  end loop;
  if jsonb_typeof(p_payload->'entries')='array' and jsonb_array_length(p_payload->'entries')>0 then
    base_id:='xwbase_'||md5(p_id);
    base_result:=public.crm_finance_action(base_id,'payout',jsonb_build_object(
      'recipient',recipient,'accountId',acc_id,'date',action_date,
      'useCredit',coalesce(p_payload->'useCredit','false'::jsonb),'entries',p_payload->'entries'));
    txid:='fv2_'||base_id;
    select data into tx from public.finance where id=txid for update;
    if tx is null then raise exception 'Не найдена созданная выплата'; end if;
    base_cash:=crm_private.fin_num(tx,'amount');
    tx:=tx||jsonb_build_object('amount',base_cash+total,
      'settledAmount',crm_private.fin_num(tx,'settledAmount')+total,
      'payoutLines',coalesce(tx->'payoutLines','[]'::jsonb)||lines,
      'comment',coalesce(tx->>'comment','Выплата')||' · доп. работа');
    update public.finance set data=tx where id=txid;
  else
    tx:=jsonb_build_object('id',txid,'kind','tx','date',action_date,'type','expense','amount',total,'settledAmount',total,'creditUsed',0,
      'accountId',acc_id,'toAccountId','','category','Доп. работа — '||recipient,
      'source','extra_work_payout','recipient',recipient,'payoutLines',lines,
      'comment','Доп. работа','author',p.name,'created',ms,'direction','toys');
    insert into public.finance values(txid,tx);
  end if;
  result:=jsonb_build_object('tasks',changed,'orders',coalesce(base_result->'orders','[]'::jsonb),'finance',jsonb_build_array(tx),
    'total',coalesce(crm_private.fin_num(tx,'settledAmount'),crm_private.fin_num(tx,'amount')),
    'cash',crm_private.fin_num(tx,'amount'),'commandId',p_id);
  insert into crm_private.extra_work_commands(id,actor,request,result) values(p_id,p.user_id,p_payload,result);
  return result;
end;
$$;

revoke all on function public.crm_extra_work_payout(text,jsonb) from public,anon;
grant execute on function public.crm_extra_work_payout(text,jsonb) to authenticated;

-- Masters receive only their own assigned tasks and a safe subset of extra-work data.
create or replace function public.crm_master_tasks()
returns table(id text, data jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare p public.crm_profiles;
begin
  p:=crm_private.profile();
  if p.user_id is null or p.role<>'master' then raise exception 'Access denied' using errcode='42501'; end if;
  return query
    select t.id::text,
      case when t.data->>'kind'='extra_work' then crm_private.pick(t.data,array['id','kind','text','amount','to','orderId','orderNum','delivery','done','created','paidAt']) else t.data end
    from public.tasks t where t.data->>'to'=p.master_name order by t.id::text;
end;
$$;
revoke all on function public.crm_master_tasks() from public,anon;
grant execute on function public.crm_master_tasks() to authenticated;
commit;
