import fs from 'node:fs';
import assert from 'node:assert/strict';

const source=fs.readFileSync('index.html','utf8');
const migration=fs.readFileSync('supabase/migrations/015-split-ozon-accounts.sql','utf8');

assert.match(source,/{name:'Озон Банк Даша', type:'bank',owner:'dasha'}/,'Dasha Ozon account is a default');
assert.match(source,/{name:'Озон Банк Саша', type:'bank',owner:'sasha'}/,'Sasha Ozon account is a default');
assert.match(source,/function canUseBankAccount\(a\)\{return role!=='director'\|\|bankAccountOwner\(a\)==='dasha';\}/,'director transactions are restricted');
assert.match(source,/bankAccountOwner\(a\)==='dasha'\|\|n==='озон банк саша'/,'director can view Sasha Ozon account');
assert.match(source,/function bankUsableAccounts\(\)\{return bankAccounts\(\)\.filter\(canUseBankAccount\);\}/,'visible and usable account lists are separate');
assert.match(source,/role==='manager'\?'<button class="btn btn-secondary btn-sm"[^\n]+⇄ Перевод/,'only Sasha sees the transfer button');
assert.match(source,/Даше доступен только счёт «Озон Банк Даша»/,'client blocks an inaccessible account');
assert.match(source,/await ensureOzonAccountsSplit\(\)/,'account split runs after cloud data loads');
assert.match(migration,/name','Озон Банк Даша','owner','dasha'/,'legacy Ozon balance is assigned to Dasha');
assert.match(migration,/name','Озон Банк Саша'.*?'startBalance',0/s,'Sasha account starts at zero');
assert.match(migration,/create trigger crm_guard_director_bank_account/,'server enforces the role restriction');

console.log('PASS split Ozon accounts and Dasha access restrictions');
