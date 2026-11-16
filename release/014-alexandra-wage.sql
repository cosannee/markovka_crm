-- Apply once after publishing the matching client. No bank entries are changed.
begin;
do $migration$
declare definition text; old_clause text := 'case when nm=''Даша'' then 300 else 0 end';
begin
 definition := pg_get_functiondef('crm_private.fin_calc(jsonb)'::regprocedure);
 if position('alexandra_wage_v1' in definition)>0 then return; end if;
 if position(old_clause in definition)=0 or position('wage:=round(wage);' in definition)=0 then
  raise exception 'Unexpected finance calculation. Stop and inspect before changing rates.';
 end if;
 definition:=replace(definition,old_clause,'case when nm=''Даша'' or (nm=''Александра'' and coalesce(j->>''postpayPaid'',''false'')<>''true'') then 300 else 0 end');
 definition:=replace(definition,'wage:=round(wage);', $patch$
 -- alexandra_wage_v1: preserve completed payments, including the new rate after payout.
 if nm='Александра' and j->>'postpayPaid'='true' then
  if j->'financePayments' ? 'postpay' then
   wage:=crm_private.fin_num(j->'financePayments'->'postpay','amount')+crm_private.fin_num(j->'financePayments'->'advance','amount');
  elsif j->'masterPaidActual' ? 'postpay' then
   wage:=crm_private.fin_num(j->'masterPaidActual','postpay')+crm_private.fin_num(j->'masterPaidActual','advance');
  end if;
 end if;
 wage:=round(wage);
 $patch$);
 execute definition;
end $migration$;
-- Existing settings are preserved. Abort rather than invent a missing settings row.
do $$begin
 update public.finance set data=data||'{"alexandraWageV1":true}'::jsonb where id='app-settings';
 if not found then raise exception 'app-settings missing: inspect before enabling';end if;
end$$;
commit;
