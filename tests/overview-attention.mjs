import fs from 'node:fs';
import assert from 'node:assert/strict';

const source=fs.readFileSync('index.html','utf8');
const overview=source.slice(source.indexOf('function tplWeekOverview(){'),source.indexOf('function sdekExportText(){'));

assert.match(source,/overviewLimit=5/,'attention list starts compact');
assert.match(overview,/class="attention-filters"/,'attention filters are visible at the top');
assert.match(overview,/class="attention-list"/,'attention orders use compact rows');
assert.match(overview,/class="overview-tools"/,'secondary overview sections are collapsible');
assert.doesNotMatch(overview,/card overview-order/,'large order cards were removed from attention');
assert.match(source,/{name:'Света', varRate:0\.40, advancePct:0,/,'Sveta uses one final payout instead of an advance split');
assert.match(fs.readFileSync('supabase/migrations/014-disable-advances.sql','utf8'),/Авансовая система отключена/,'server migration disables new advances');

console.log('PASS compact attention dashboard and Sveta final-only payout');
