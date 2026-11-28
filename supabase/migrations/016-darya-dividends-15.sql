-- Update the payout calculator without rewriting orders or payout history.
do $migration$
declare
  definition text := pg_get_functiondef('crm_private.fin_calc(jsonb)'::regprocedure);
  old_formula constant text := $old$'dividend',round(greatest(0,profit)*.1),$old$;
  new_formula constant text := $new$'dividend',round(greatest(0,profit)*.15),$new$;
begin
  if strpos(definition,old_formula)=0 and strpos(definition,new_formula)>0 then return; end if;
  if strpos(definition,old_formula)=0 or strpos(definition,new_formula)>0
     or strpos(substr(definition,strpos(definition,old_formula)+length(old_formula)),old_formula)>0 then
    raise exception 'Unexpected finance calculation; dividend rate was not changed';
  end if;
  execute replace(definition,old_formula,new_formula);
end
$migration$;
