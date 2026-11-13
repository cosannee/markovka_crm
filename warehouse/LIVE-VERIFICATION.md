# Проверка рабочего Supabase — склад

Выполнено через существующую авторизацию CRM. Пароли и токены в отчёт не включены.

- PASS: real account login and roles
- PASS: master and director cannot create catalog entries
- PASS: manager can upload a private test image
- PASS: unassigned master cannot read private image
- PASS: unknown stock is not zero and assigned image is readable
- PASS: master cannot start another warehouse inventory
- PASS: save zero, read back, repeat without duplicate
- PASS: Dasha cannot see trainee warehouse or test balance

Тестовый материал архивирован, оба назначения отключены, история сохранена. Для мастерских операций использован Стажёр; Даша проверена только чтением и запрещённой попыткой создания категории. У Александры и Стажёра созданы технические записи склада без активных назначений — склад останется пустым до реального наполнения.

Проверка настоящего Storage API: администратор загрузил PNG; без назначения мастер не получил ссылку, после назначения получил и загрузил файл по временной ссылке. Тестовое изображение осталось в приватном хранилище как часть архивной тестовой записи.

Ограничения: это сквозная проверка серверных API и авторизации, не ручная проверка на физическом iPhone. Мобильный интерфейс ранее проверен локально на 430×932 с тестовыми ответами. Публикация не выполнена и требует отдельного подтверждения.
