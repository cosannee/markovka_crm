-- Transactional finance for Markovka. Adds no anonymous access; preserves old rows.
begin;
create table if not exists crm_private.finance_commands (
 id text primary key, actor uuid not null, request jsonb not null, result jsonb not null,
 created_at timestamptz not null default now()
);
alter table crm_private.finance_commands enable row level security;
revoke all on crm_private.finance_commands from public,anon,authenticated;

create or replace function crm_private.fin_num(j jsonb,k text,d numeric default 0) returns numeric
language plpgsql immutable set search_path='' as $$
begin return coalesce(nullif(j->>k,'')::numeric,d); exception when others then return d; end $$;
create or replace function crm_private.fin_calc(j jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare it jsonb; its jsonb; st jsonb; lg jsonb; nm text:=j->>'master'; w numeric; q numeric; base numeric;
 total numeric:=0; wage numeric:=0; qty numeric:=0; grams numeric:=0; materials numeric; commission numeric; profit numeric;
 rate numeric; closed boolean; at_ms numeric; adv numeric;
begin
 its:=case when jsonb_typeof(j->'items')='array' and jsonb_array_length(j->'items')>0 then j->'items' else jsonb_build_array(j) end;
 for it in select value from jsonb_array_elements(its) loop
  q:=greatest(1,crm_private.fin_num(it,'count',1)); w:=crm_private.fin_num(it,'weightG',crm_private.fin_num(it,'weight'));
  total:=total+crm_private.fin_num(it,'price')*q;qty:=qty+q;grams:=grams+w*q;
  base:=case when w<1900 then 2300 when w<2500 then 2500 when w<3000 then 2700 when w<3400 then 2800 when w<3800 then 2900 when w<4400 then 3100 when w<=5500 then 3400 else floor((1800+w*.3)/100)*100 end;
  wage:=wage+(base+crm_private.fin_num(it,'embCount')*400+case when nm='Даша' then 300 else 0 end+case when it->>'bandOn'='true' then 200 else 0 end+case when it->>'capOn'='true' then 300 else 0 end)*q;
 end loop;
 closed:=case when jsonb_typeof(j->'closed')='boolean' then (j->>'closed')::boolean else j->>'status' in ('done','sent') and total>0 and crm_private.fin_num(j,'prepaid')>=total end;
 at_ms:=crm_private.fin_num(j,'closedAt',crm_private.fin_num(j,'created'));
 if j->>'urgent'='true' and (not closed or at_ms>=1786284000000) then wage:=wage*1.5;end if;
 wage:=round(wage);adv:=case when nm in ('Даша','Александра') then 0 else round(wage*.3) end;
 rate:=case nm when 'Даша' then .25 when 'Света' then .4 when 'Цветочек' then .19 when 'Юлия' then .28 when 'Вика' then .28 when 'Виктория' then .28 when 'Александра' then .19 else .4 end;
 select data into st from public.finance where id='app-settings';
 if j->>'status'='archived' and crm_private.fin_num(j,'varRate')>0 then rate:=crm_private.fin_num(j,'varRate');
 elsif closed then
  for lg in select value from jsonb_array_elements(coalesce(st->'rateLog',case when st ? 'varRates' then jsonb_build_array(jsonb_build_object('at',st->'updatedAt','rates',st->'varRates')) else '[]'::jsonb end)) order by crm_private.fin_num(value,'at') loop
   if crm_private.fin_num(lg,'at')<=at_ms and crm_private.fin_num(lg->'rates',nm)>0 then rate:=crm_private.fin_num(lg->'rates',nm);end if;
  end loop;
 elsif crm_private.fin_num(st->'varRates',nm)>0 then rate:=crm_private.fin_num(st->'varRates',nm);end if;
 materials:=700*qty+grams*rate;commission:=greatest(0,round((total-materials)*.2));
 profit:=total-materials-commission-wage-case when nm='Даша' then 350*qty else 0 end;
 return jsonb_build_object('total',total,'master',wage,'advance',adv,'postpay',wage-adv,'sasha',commission,'dividend',round(greatest(0,profit)*.1),'closed',closed,'closedAt',at_ms,'materials',materials,'profit',profit,'version','2026-10-27');
end $$;
create or replace function crm_private.fin_flag(k text) returns text language sql immutable set search_path='' as $$
 select case k when 'advance' then 'advancePaid' when 'postpay' then 'postpayPaid' when 'sasha' then 'sashaPaid' when 'dividend' then 'dividendPaid' end;
$$;
create or replace function crm_private.fin_paid(j jsonb,k text,c jsonb) returns numeric language sql immutable set search_path='' as $$
 select case when j->'financePayments' ? k then crm_private.fin_num(j->'financePayments'->k,'amount')
 when j->>crm_private.fin_flag(k)='true' then crm_private.fin_num(c,k) else 0 end;
$$;

create or replace function public.crm_finance_action(p_id text,p_action text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p public.crm_profiles; old_cmd crm_private.finance_commands; req jsonb; result jsonb; e jsonb; j jsonb; c jsonb; rec jsonb; tx jsonb; s jsonb; funding jsonb; credit jsonb;
 oid text; k text; who text; txid text; sid text; lineid text; mode text; acc text; action_date text; reason text; kindflag text;
 amount numeric; total numeric:=0; cash numeric:=0; used numeric:=0; line_cash numeric; take numeric; available numeric; before_paid numeric; paid_adv numeric;
 ms bigint:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
 changed_orders jsonb:='[]'; changed_finance jsonb:='[]'; lines jsonb:='[]'; credits jsonb:='[]'; seen text[]:='{}'; existing jsonb; recipient text; old_payment jsonb;
begin
 p:=crm_private.profile();if p.user_id is null or p.role not in ('manager','director') then raise exception 'Нет доступа' using errcode='42501';end if;
 if p_id is null or length(p_id)<16 or length(p_id)>100 or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Неверный запрос';end if;
 -- Serialize financial commands. Row locks additionally protect against ordinary order edits.
 perform pg_advisory_xact_lock(27102026,4);
 req:=jsonb_build_object('action',p_action,'payload',p_payload);
 select * into old_cmd from crm_private.finance_commands where id=p_id;
 if found then
  if old_cmd.actor<>p.user_id or old_cmd.request<>req then raise exception 'Номер операции уже использован';end if;
  -- A retry must not overwrite later edits in the browser with the original snapshot.
  result:=old_cmd.result;
  select coalesce(jsonb_agg(o.data),'[]') into changed_orders from public.orders o where o.id in (select value->>'id' from jsonb_array_elements(result->'orders'));
  select coalesce(jsonb_agg(f.data),'[]') into changed_finance from public.finance f where f.id in (select value->>'id' from jsonb_array_elements(result->'finance'));
  return result||jsonb_build_object('orders',changed_orders,'finance',changed_finance);
 end if;
 perform set_config('crm.finance_action','yes',true);
 txid:='fv2_'||p_id;acc:=p_payload->>'accountId';
 action_date:=coalesce(nullif(p_payload->>'date',''),to_char(now() at time zone 'Asia/Vladivostok','YYYY-MM-DD'));
 if action_date !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Проверьте дату';end if;
 perform action_date::date;
 reason:=btrim(coalesce(p_payload->>'reason',''));
 if p_action in ('payout','receive','customer_refund','settlement_return') then
  select data into rec from public.finance where id=acc for update;
  if rec is null or rec->>'kind'<>'account' or rec->>'archived'='true' or rec->>'type' in ('savings','debt') then raise exception 'Выберите действующий расчётный счёт';end if;
 end if;
 if p_action='bank_import' then
  if jsonb_typeof(p_payload->'records') is distinct from 'array' or jsonb_array_length(p_payload->'records') not between 1 and 100 then raise exception 'Выберите от 1 до 100 операций';end if;
  for e in select value from jsonb_array_elements(p_payload->'records') loop
   used:=used+1;
   result:=public.crm_finance_action('import_'||md5(p_id)||'_'||used::text,'bank_tx',jsonb_build_object('record',e,'date',e->>'date'));
   changed_finance:=changed_finance||(result->'finance');
  end loop;
 elsif p_action='bank_tx' then
  existing:=null;txid:=coalesce(nullif(p_payload->>'txId',''),txid);
  if nullif(p_payload->>'txId','') is not null then
   select data into existing from public.finance where id=txid for update;
   if existing is null or p_payload->'expectedTx' is distinct from existing then raise exception 'Операция изменилась';end if;
   if existing->>'kind' is distinct from 'tx' or existing->>'voided'='true' or existing->>'source' in ('payout','finance_v2') or existing ? 'paymentLines' or existing ? 'financeCancellations' or nullif(existing->>'orderId','') is not null then raise exception 'Связанную операцию исправляйте через выплату или сверку';end if;
   if length(reason)<3 then raise exception 'Укажите причину изменения';end if;
  end if;
  e:=p_payload->'record';amount:=round(crm_private.fin_num(e,'amount'),2);k:=e->>'type';acc:=e->>'accountId';
  if k is null or k not in ('income','expense','transfer') or amount<=0 or amount>100000000 then raise exception 'Проверьте тип и сумму';end if;
  if not exists(select 1 from public.finance where id=acc and data->>'kind'='account' and coalesce(data->>'archived','false')<>'true') then raise exception 'Счёт не найден';end if;
  if k='transfer' and (acc=e->>'toAccountId' or not exists(select 1 from public.finance where id=e->>'toAccountId' and data->>'kind'='account' and coalesce(data->>'archived','false')<>'true')) then raise exception 'Проверьте счёт перевода';end if;
  if nullif(e->>'orderId','') is not null and not exists(select 1 from public.orders where id=e->>'orderId') then raise exception 'Заказ не найден';end if;
  rec:=coalesce(existing,'{}')||crm_private.pick(e,array['type','accountId','toAccountId','category','comment','orderId','merchant'])||jsonb_build_object('id',txid,'kind','tx','amount',amount,'date',action_date,'source',coalesce(existing->>'source','manual'),'author',coalesce(existing->>'author',p.name),'created',coalesce(existing->'created',to_jsonb(ms)),'direction','toys','financeManaged',true);
  if existing is not null then rec:=rec||jsonb_build_object('changeHistory',coalesce(existing->'changeHistory','[]')||jsonb_build_array(jsonb_build_object('before',existing-'changeHistory','at',ms,'by',p.name,'reason',reason)));end if;
  insert into public.finance values(txid,rec) on conflict(id) do update set data=excluded.data;changed_finance:=jsonb_build_array(rec);
 elsif p_action='bank_void' then
  txid:=p_payload->>'txId';select data into tx from public.finance where id=txid for update;
  if tx is null or p_payload->'expectedTx' is distinct from tx or length(reason)<3 then raise exception 'Операция изменилась или не указана причина';end if;
  if tx->>'kind' is distinct from 'tx' or tx->>'voided'='true' or nullif(tx->>'orderId','') is not null or tx ? 'financeCancellations' or tx->>'source' in ('payout','finance_v2') or tx ? 'paymentLines' then raise exception 'Связанную операцию отменяйте через выплату или возврат';end if;
  tx:=tx||jsonb_build_object('originalAmount',coalesce(tx->'originalAmount',tx->'amount'),'amount',0,'voided',true,'voidReason',reason,'voidedAt',ms,'voidedBy',p.name);
  update public.finance set data=tx where id=txid;changed_finance:=jsonb_build_array(tx);
 elsif p_action='payout' then
  if jsonb_typeof(p_payload->'entries') is distinct from 'array' or jsonb_array_length(p_payload->'entries') not between 1 and 500 then raise exception 'Выберите заказы';end if;
  recipient:=p_payload->>'recipient';
  if p_payload->>'useCredit'='true' then
   select coalesce(jsonb_agg(data order by id),'[]') into credits from public.finance where data->>'kind'='settlement' and data->>'recipient'=recipient and data->>'mode'='credit' and crm_private.fin_num(data,'remaining')>0;
  end if;
  for e in select value from jsonb_array_elements(p_payload->'entries') order by value->>'orderId',value->>'kind' loop
   oid:=e->>'orderId';k:=e->>'kind';kindflag:=crm_private.fin_flag(k);
   if kindflag is null or oid||':'||k=any(seen) then raise exception 'Неверный состав выплаты';end if;seen:=array_append(seen,oid||':'||k);
   select data into j from public.orders where id=oid for update;
   if j is null then raise exception 'Заказ не найден';end if;
   if e->'expected' is distinct from crm_private.pick(j,array['master','status','items','price','weightG','weight','count','embCount','bandOn','capOn','urgent','closed','closedAt','readyAt','advancePaid','postpayPaid','sashaPaid','dividendPaid','financePayments','varRate']) then raise exception 'Заказ изменился. Обновите расчёт';end if;
   c:=crm_private.fin_calc(j);who:=case k when 'sasha' then 'Александра — комиссия' when 'dividend' then 'Дарья — дивиденды' else j->>'master' end;
   if who is distinct from recipient then raise exception 'Получатель изменился';end if;
   if j->>kindflag='true' then raise exception 'Эта часть уже выплачена';end if;
   if k='advance' and (j->>'status' not in ('new','nextweek','work') or crm_private.fin_num(c,'advance')<=0) then raise exception 'Аванс сейчас недоступен';end if;
   if k='postpay' and j->>'status' not in ('ready','planned','sent','done','archived') then raise exception 'Заказ ещё не готов';end if;
   if k='postpay' and j->>'master'='Даша' and coalesce(nullif(j->>'readyAt','')::numeric,nullif(j->>'closedAt','')::numeric,case when j->>'status' in ('ready','planned') then 1789912800000 else crm_private.fin_num(j,'created') end)<1789912800000 then raise exception 'Исторический заказ вне периода выплат';end if;
   if k in ('sasha','dividend') and (c->>'closed'<>'true' or crm_private.fin_num(c,'closedAt')<1786888800000) then raise exception 'Заказ ещё не закрыт для начисления';end if;
   if k='postpay' and j->>'advancePaid'='true' and not coalesce(j->'financePayments' ? 'advance',false) then
    if not (e ? 'legacyAdvance') or crm_private.fin_num(e,'legacyAdvance')<0 then raise exception 'Подтвердите фактически выплаченный старый аванс';end if;
    j:=jsonb_set(j,'{financePayments}',coalesce(j->'financePayments','{}')||jsonb_build_object('advance',jsonb_build_object('amount',crm_private.fin_num(e,'legacyAdvance'),'recipient',j->>'master','legacy',true,'confirmedBy',p.name,'at',ms)),true);
   end if;
   paid_adv:=crm_private.fin_paid(j,'advance',c);
   amount:=case k when 'postpay' then greatest(0,crm_private.fin_num(c,'master')-paid_adv) else crm_private.fin_num(c,k) end;
   if amount<=0 or abs(amount-crm_private.fin_num(e,'amount'))>.01 then raise exception 'Сумма изменилась. Обновите расчёт';end if;
   lineid:=oid||':'||k;line_cash:=amount;funding:='[]';
   for credit in select value from jsonb_array_elements(credits) loop
    select data into s from public.finance where id=credit->>'id' for update;
    take:=least(line_cash,crm_private.fin_num(s,'remaining'));
    if take>0 then
     s:=s||jsonb_build_object('remaining',crm_private.fin_num(s,'remaining')-take,'updatedAt',ms);
     update public.finance set data=s where id=s->>'id';changed_finance:=changed_finance||jsonb_build_array(s);
     funding:=funding||jsonb_build_array(jsonb_build_object('id',s->>'id','amount',take));line_cash:=line_cash-take;
    end if;
   end loop;
   e:=jsonb_build_object('orderId',oid,'orderNum',j->>'num','master',who,'type',k,'amount',amount,'lineId',lineid,'cash',line_cash,'credits',funding,'calculation',c);
   lines:=lines||jsonb_build_array(e);total:=total+amount;cash:=cash+line_cash;
   j:=jsonb_set(j,'{financePayments}',coalesce(j->'financePayments','{}')||jsonb_build_object(k,jsonb_build_object('amount',amount,'txId',txid,'lineId',lineid,'recipient',who,'at',ms,'calculation',c)),true)||jsonb_build_object(kindflag,true);
   if k='advance' then j:=j||jsonb_build_object('advancePayment',jsonb_build_object('txId',txid,'master',who,'amount',amount,'paidAt',ms));end if;
   update public.orders set data=j where id=oid;changed_orders:=changed_orders||jsonb_build_array(j);
  end loop;
  rec:=jsonb_build_object('id',txid,'kind','tx','date',action_date,'type','expense','amount',cash,'settledAmount',total,'creditUsed',total-cash,'accountId',acc,'category',case when recipient='Дарья — дивиденды' then 'Дивиденды/выводы' else 'ЗП '||recipient end,'source','finance_v2','recipient',recipient,'payoutLines',lines,'comment','Выплата · '||(select string_agg(distinct x->>'orderNum',', ') from jsonb_array_elements(lines) x),'author',p.name,'created',ms,'direction','toys');
  insert into public.finance values(txid,rec);changed_finance:=changed_finance||jsonb_build_array(rec);
 elsif p_action='cancel' then
  oid:=p_payload->>'orderId';k:=p_payload->>'kind';mode:=p_payload->>'mode';kindflag:=crm_private.fin_flag(k);
  if kindflag is null or mode is null or mode not in ('void','credit','refund') or length(reason)<3 then raise exception 'Выберите действие с деньгами и укажите причину';end if;
  select data into j from public.orders where id=oid for update;
  if j is null or j->>kindflag is distinct from 'true' then raise exception 'Выплата уже отменена или заказ не найден';end if;
  if p_payload->'expected' is distinct from j then raise exception 'Заказ изменился. Откройте отмену заново';end if;
  old_payment:=j->'financePayments'->k;txid:=coalesce(old_payment->>'txId',nullif(p_payload->>'txId',''));recipient:=coalesce(old_payment->>'recipient',p_payload->>'recipient');
  amount:=case when old_payment ? 'amount' then crm_private.fin_num(old_payment,'amount') else crm_private.fin_num(p_payload,'amount') end;
  if amount<=0 or amount>10000000 or nullif(recipient,'') is null then raise exception 'Подтвердите фактическую сумму и получателя';end if;
  if k='advance' and j->>'postpayPaid'='true' then raise exception 'Сначала отмените итоговую выплату';end if;
  if txid is not null then
   select data into tx from public.finance where id=txid for update;
   if tx is null or tx->>'type'<>'expense' then raise exception 'Исходная банковская операция не найдена';end if;
   if tx->>'source'='finance_v2' then
    select value into e from jsonb_array_elements(tx->'payoutLines') where value->>'lineId'=old_payment->>'lineId';
    if e is null or e->>'canceled'='true' or crm_private.fin_num(e,'amount')<>amount then raise exception 'Состав исходной выплаты не совпадает';end if;
   else
    if p_payload->'expectedTx' is distinct from tx then raise exception 'Банковская операция изменилась';end if;
    if tx->>'source'<>'payout' or exists(select 1 from jsonb_array_elements(coalesce(tx->'financeCancellations','[]')) z where z->>'orderId'=oid and z->>'kind'=k) then raise exception 'Выберите другую исходную выплату';end if;
    e:=jsonb_build_object('cash',amount,'credits','[]');
   end if;
  elsif mode='void' then raise exception 'Для отмены записи банка выберите исходную операцию';end if;
  if tx is not null then
   if mode='void' then
    line_cash:=crm_private.fin_num(e,'cash');
    if line_cash>crm_private.fin_num(tx,'amount') then raise exception 'Сумма превышает остаток банковской операции';end if;
    tx:=tx||jsonb_build_object('originalAmount',coalesce(tx->'originalAmount',tx->'amount'),'amount',crm_private.fin_num(tx,'amount')-line_cash);
    for credit in select value from jsonb_array_elements(coalesce(e->'credits','[]')) loop
     select data into s from public.finance where id=credit->>'id' for update;
     if s is null then raise exception 'Зачёт не найден';end if;
     s:=s||jsonb_build_object('remaining',crm_private.fin_num(s,'remaining')+crm_private.fin_num(credit,'amount'),'updatedAt',ms);update public.finance set data=s where id=s->>'id';changed_finance:=changed_finance||jsonb_build_array(s);
    end loop;
   end if;
   if tx->>'source'='finance_v2' then
    select jsonb_agg(case when value->>'lineId'=old_payment->>'lineId' then value||jsonb_build_object('canceled',true,'cancelMode',mode) else value end) into lines from jsonb_array_elements(tx->'payoutLines');
    tx:=tx||jsonb_build_object('payoutLines',lines);
   end if;
   tx:=tx||jsonb_build_object('financeCancellations',coalesce(tx->'financeCancellations','[]')||jsonb_build_array(jsonb_build_object('orderId',oid,'kind',k,'amount',amount,'mode',mode,'at',ms,'by',p.name,'reason',reason)));
   update public.finance set data=tx where id=txid;changed_finance:=changed_finance||jsonb_build_array(tx);
  end if;
  if mode in ('credit','refund') then
   sid:='settlement_'||p_id;s:=jsonb_build_object('id',sid,'kind','settlement','recipient',recipient,'mode',mode,'amount',amount,'remaining',amount,'orderId',oid,'orderNum',j->>'num','txId',txid,'reason',reason,'author',p.name,'created',ms);
   insert into public.finance values(sid,s);changed_finance:=changed_finance||jsonb_build_array(s);
  end if;
  j:=jsonb_set(j,'{financePayments}',coalesce(j->'financePayments','{}')||jsonb_build_object(k,jsonb_build_object('amount',0,'canceledAt',ms)),true)||jsonb_build_object(kindflag,false,'financeCancellationHistory',coalesce(j->'financeCancellationHistory','[]')||jsonb_build_array(jsonb_build_object('id',p_id,'kind',k,'mode',mode,'amount',amount,'recipient',recipient,'txId',txid,'reason',reason,'at',ms,'by',p.name)));
  if k='advance' then j:=j-'advancePayment';end if;
  update public.orders set data=j where id=oid;changed_orders:=jsonb_build_array(j);
 elsif p_action in ('receive','customer_refund') then
  oid:=p_payload->>'orderId';select data into j from public.orders where id=oid for update;
  if j is null then raise exception 'Заказ не найден';end if;c:=crm_private.fin_calc(j);
  if crm_private.fin_num(j,'prepaid')<>crm_private.fin_num(p_payload,'expectedPrepaid') or crm_private.fin_num(c,'total')<>crm_private.fin_num(p_payload,'expectedTotal') then raise exception 'Оплата или цена заказа изменилась';end if;
  amount:=round(crm_private.fin_num(p_payload,'amount'),2);
  if amount<0 or (amount=0 and not (p_action='receive' and p_payload->>'close'='true')) or amount>10000000 then raise exception 'Проверьте сумму';end if;
  before_paid:=crm_private.fin_num(j,'prepaid');
  if p_action='customer_refund' and (amount>before_paid or length(reason)<3) then raise exception 'Проверьте сумму возврата и причину';end if;
  j:=j||jsonb_build_object('prepaid',before_paid+case when p_action='receive' then amount else -amount end);
  if p_payload->>'close'='true' and crm_private.fin_num(j,'prepaid')<crm_private.fin_num(c,'total') then raise exception 'Для закрытия нужна полная оплата';end if;
  if p_action='receive' and p_payload->>'close'='true' then
   j:=j||jsonb_build_object('closed',true,'closedAt',coalesce(j->'closedAt',to_jsonb(ms)));
   if p.role='manager' and j->>'status'='ready' and nullif(btrim(j->>'sdekNum'),'') is not null then j:=j||jsonb_build_object('status','planned','sdekPreviousStatus','ready');end if;
  elsif p_action='customer_refund' then
   j:=j||jsonb_build_object('closed',false);j:=j-'closedAt';
   if j->>'status'='planned' then j:=j||jsonb_build_object('status',coalesce(j->>'sdekPreviousStatus','ready'));end if;
  end if;
  j:=j||jsonb_build_object('financePaymentHistory',coalesce(j->'financePaymentHistory','[]')||jsonb_build_array(jsonb_build_object('id',p_id,'type',p_action,'amount',amount,'at',ms,'by',p.name)));
  update public.orders set data=j where id=oid;changed_orders:=jsonb_build_array(j);
  if amount>0 then
   rec:=jsonb_build_object('id',txid,'kind','tx','date',action_date,'type',case when p_action='receive' then 'income' else 'expense' end,'amount',amount,'accountId',acc,'category',case when p_action='customer_refund' then 'Возврат клиенту' when before_paid>0 then 'Доплата заказа' else 'Предоплата заказа' end,'orderId',oid,'paymentLines',jsonb_build_array(jsonb_build_object('orderId',oid,'amount',amount,'type',p_action)),'source','finance_v2','comment',reason,'author',p.name,'created',ms,'direction','toys');
   insert into public.finance values(txid,rec);changed_finance:=jsonb_build_array(rec);
  end if;
 elsif p_action='settlement_return' then
  sid:=p_payload->>'settlementId';select data into s from public.finance where id=sid for update;amount:=round(crm_private.fin_num(p_payload,'amount'),2);
  if s is null or s->>'kind'<>'settlement' or amount<=0 or amount>crm_private.fin_num(s,'remaining') or crm_private.fin_num(s,'remaining')<>crm_private.fin_num(p_payload,'expectedRemaining') then raise exception 'Остаток изменился. Обновите список';end if;
  s:=s||jsonb_build_object('remaining',crm_private.fin_num(s,'remaining')-amount,'updatedAt',ms);update public.finance set data=s where id=sid;
  rec:=jsonb_build_object('id',txid,'kind','tx','type','income','date',action_date,'amount',amount,'accountId',acc,'category','Возврат аванса','source','finance_v2','settlementId',sid,'comment','Возврат от '||(s->>'recipient'),'author',p.name,'created',ms,'direction','toys');
  insert into public.finance values(txid,rec);changed_finance:=jsonb_build_array(s,rec);
 elsif p_action in ('acknowledge','adjust_payment') then
  oid:=p_payload->>'orderId';select data into j from public.orders where id=oid for update;
  if j is null or p_payload->'expected' is distinct from j or length(reason)<3 then raise exception 'Заказ изменился или не указана причина';end if;
  if p_action='adjust_payment' then
   amount:=round(crm_private.fin_num(p_payload,'amount',-1),2);if amount<0 or amount>10000000 then raise exception 'Проверьте сумму';end if;
   j:=j||jsonb_build_object('prepaid',amount);
   c:=crm_private.fin_calc(j);
   if amount<crm_private.fin_num(c,'total') then j:=(j-'closedAt')||jsonb_build_object('closed',false);if j->>'status'='planned' then j:=j||jsonb_build_object('status',coalesce(j->>'sdekPreviousStatus','ready'));end if;end if;
  end if;
  select coalesce(sum(case when t.data->>'type'='expense' then -crm_private.fin_num(z,'amount') else crm_private.fin_num(z,'amount') end),0) into amount
  from public.finance t cross join lateral jsonb_array_elements(coalesce(t.data->'paymentLines',case when nullif(t.data->>'orderId','') is not null and t.data->>'type'='income' then jsonb_build_array(jsonb_build_object('orderId',t.data->>'orderId','amount',t.data->'amount')) else '[]'::jsonb end)) z
  where t.data->>'kind'='tx' and z->>'orderId'=oid;
  j:=j||jsonb_build_object('financeReview',jsonb_build_object('prepaid',j->'prepaid','bank',amount,'reason',reason,'by',p.name,'at',ms));
  update public.orders set data=j where id=oid;changed_orders:=jsonb_build_array(j);
 elsif p_action='link_income' then
  txid:=p_payload->>'txId';select data into tx from public.finance where id=txid for update;
  oid:=p_payload->>'orderId';select data into j from public.orders where id=oid for update;
  if tx is null or j is null or tx->>'type'<>'income' or tx ? 'settlementId' then raise exception 'Выберите поступление и заказ';end if;
  if p_payload->'expectedTx' is distinct from tx then raise exception 'Операция изменилась';end if;
  amount:=round(crm_private.fin_num(p_payload,'amount'),2);
  if coalesce(tx->>'orderId','')<>'' and not (tx ? 'paymentLines') then raise exception 'Операция уже связана с заказом';end if;
  select coalesce(sum(crm_private.fin_num(value,'amount')),0) into used from jsonb_array_elements(coalesce(tx->'paymentLines','[]'));
  if amount<=0 or amount+used>crm_private.fin_num(tx,'amount') then raise exception 'Сумма превышает нераспределённую часть';end if;
  tx:=tx||jsonb_build_object('paymentLines',coalesce(tx->'paymentLines','[]')||jsonb_build_array(jsonb_build_object('orderId',oid,'amount',amount,'type','receive')),'linkedBy',p.name,'linkedAt',ms);
  update public.finance set data=tx where id=txid;changed_finance:=jsonb_build_array(tx);
 else raise exception 'Неизвестное действие';end if;
 rec:=jsonb_build_object('id','event_'||p_id,'kind','finance_event','action',p_action,'author',p.name,'actorId',p.user_id,'created',ms,'reason',reason,'orderIds',(select coalesce(jsonb_agg(distinct value->>'id'),'[]') from jsonb_array_elements(changed_orders)),'financeIds',(select coalesce(jsonb_agg(distinct value->>'id'),'[]') from jsonb_array_elements(changed_finance)));
 insert into public.finance values(rec->>'id',rec);changed_finance:=changed_finance||jsonb_build_array(rec);
 result:=jsonb_build_object('orders',changed_orders,'finance',changed_finance,'total',total,'cash',cash,'commandId',p_id);
 insert into crm_private.finance_commands(id,actor,request,result) values(p_id,p.user_id,req,result);
 return result;
end $$;
revoke all on function public.crm_finance_action(text,text,jsonb) from public,anon;
grant execute on function public.crm_finance_action(text,text,jsonb) to authenticated;

create or replace function crm_private.guard_finance_write() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if current_setting('crm.finance_action',true)='yes' then return case when tg_op='DELETE' then old else new end;end if;
 if tg_op in ('UPDATE','DELETE') and (old.data->>'source'='finance_v2' or old.data->>'kind' in ('settlement','finance_event') or old.data ? 'financeCancellations' or old.data ? 'linkedAt' or old.data->>'financeManaged'='true' or old.data ? 'changeHistory' or old.data->>'voided'='true') then raise exception 'Используйте отмену или сверку в разделе выплат' using errcode='42501';end if;
 if tg_op in ('UPDATE','INSERT') and (new.data->>'source'='finance_v2' or new.data->>'kind' in ('settlement','finance_event') or new.data->>'financeManaged'='true') then raise exception 'Финансовая операция должна быть проведена целиком' using errcode='42501';end if;
 return case when tg_op='DELETE' then old else new end;
end $$;
drop trigger if exists crm_guard_finance_v2 on public.finance;
create trigger crm_guard_finance_v2 before insert or update or delete on public.finance for each row execute function crm_private.guard_finance_write();
create or replace function crm_private.guard_paid_order() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if current_setting('crm.finance_action',true)='yes' then return new;end if;
 if new.data->>'master' is distinct from old.data->>'master' and (old.data->>'advancePaid'='true' or old.data->>'postpayPaid'='true') then raise exception 'Сначала оформите отмену выплат прежнему мастеру';end if;
 if new.data->'financePayments' is distinct from old.data->'financePayments' or new.data->'financeCancellationHistory' is distinct from old.data->'financeCancellationHistory' or new.data->'financePaymentHistory' is distinct from old.data->'financePaymentHistory' or new.data->'financeReview' is distinct from old.data->'financeReview' then raise exception 'Используйте финансовое действие';end if;
 if old.data ? 'financePayments' and crm_private.pick(new.data,array['advancePaid','postpayPaid','sashaPaid','dividendPaid']) is distinct from crm_private.pick(old.data,array['advancePaid','postpayPaid','sashaPaid','dividendPaid']) then raise exception 'Используйте отмену выплаты';end if;
 return new;
end $$;
drop trigger if exists crm_guard_paid_order on public.orders;
create trigger crm_guard_paid_order before update on public.orders for each row execute function crm_private.guard_paid_order();
create or replace function crm_private.master_order(j jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare result jsonb; its jsonb; total numeric; paid boolean;
begin
 result:=crm_private.pick(j,array['id','num','master','status','created','month','urgent','craftStage','masterNote','shipDate','readyAt','sentAt','closedAt','prevStatus','sdekPreviousStatus','advancePaid','postpayPaid','comment','toyType','toys','weightG','weight','heightCm','height','embCount','embText','bandOn','bandColor','capOn','capColor','gender','clothes','count']);
 if jsonb_typeof(j->'items')='array' then
  select coalesce(jsonb_agg(crm_private.pick(value,array['toyType','weightG','heightCm','embCount','embText','bandOn','bandColor','capOn','capColor','gender','clothes','count','comment']) order by ord),'[]'::jsonb)
  into its from jsonb_array_elements(j->'items') with ordinality as x(value,ord);
  result:=result||jsonb_build_object('items',its);
 end if;
 if jsonb_typeof(j->'closed')='boolean' then paid:=(j->>'closed')::boolean;
 else
  if jsonb_typeof(j->'items')='array' and jsonb_array_length(j->'items')>0 then
   select coalesce(sum(coalesce(nullif(value->>'price','')::numeric,0)*coalesce(nullif(value->>'count','')::numeric,1)),0) into total from jsonb_array_elements(j->'items');
  else total:=coalesce(nullif(j->>'price','')::numeric,0)*coalesce(nullif(j->>'count','')::numeric,1); end if;
  paid:=coalesce(j->>'status' in ('done','sent') and total>0 and coalesce(nullif(j->>'prepaid','')::numeric,0)>=total,false);
 end if;
 result:=result||jsonb_build_object('closed',paid);
 -- Waybill visible only once shipping is planned (and in shipping history).
 if j->>'status' in ('planned','sent','done','archived') then
  result:=result||crm_private.pick(j,array['sdekNum']);
 end if;
 return result||jsonb_build_object('masterPaidActual',jsonb_build_object('advance',case when j->'financePayments' ? 'advance' then j->'financePayments'->'advance'->'amount' else null end,'postpay',case when j->'financePayments' ? 'postpay' then j->'financePayments'->'postpay'->'amount' else null end));
end $$;
create or replace function crm_private.guard_order_delete() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.data ? 'financePayments' or old.data ? 'financePaymentHistory' or old.data->>'advancePaid'='true' or old.data->>'postpayPaid'='true' or old.data->>'sashaPaid'='true' or old.data->>'dividendPaid'='true' or exists(select 1 from public.finance f where f.data->>'orderId'=old.id or f.data->'paymentLines' @> jsonb_build_array(jsonb_build_object('orderId',old.id)) or f.data->'payoutLines' @> jsonb_build_array(jsonb_build_object('orderId',old.id))) then raise exception 'У заказа есть финансовая история. Перенесите его в архив';end if;
 return old;
end $$;
drop trigger if exists crm_guard_order_delete on public.orders;
create trigger crm_guard_order_delete before delete on public.orders for each row execute function crm_private.guard_order_delete();
-- Preserve master visibility without exposing client prices or bank data.
create or replace function public.crm_master_orders(p_after text default '',p_limit integer default 500)
returns table(id text,data jsonb) language plpgsql stable security definer set search_path='' as $$
declare p public.crm_profiles;
begin
 p:=crm_private.profile();if p.user_id is null or p.role<>'master' then raise exception 'Access denied' using errcode='42501';end if;
 return query select o.id::text,crm_private.master_order(o.data)||jsonb_build_object('masterPaidActual',jsonb_build_object('advance',case when o.data->'financePayments' ? 'advance' then o.data->'financePayments'->'advance'->'amount' else null end,'postpay',case when o.data->'financePayments' ? 'postpay' then o.data->'financePayments'->'postpay'->'amount' else null end)) from public.orders o where o.data->>'master'=p.master_name and o.id::text>p_after order by o.id::text limit least(greatest(p_limit,1),500);
end $$;
revoke all on all functions in schema crm_private from public,anon,authenticated;
commit;
