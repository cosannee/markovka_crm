import fs from 'node:fs';
import assert from 'node:assert/strict';

const source=fs.readFileSync('index.html','utf8');

assert.match(source,/role==='director'\?\['list','week'\]/,'Dasha primary navigation contains only workspace and week');
assert.match(source,/overview:'Заказы, оплата и отправка — что требует внимания'/,'overview remains available in More');
assert.match(source,/payments:'Выплаты по заказам и сотрудникам'/,'payments has a clear description in More');

console.log('PASS Dasha primary navigation and More sections');
