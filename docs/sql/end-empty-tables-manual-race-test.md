# Slice C: the two races, tested by hand

STATUS: written, NOT RUN yet.

`end-empty-tables-verification.sql` runs in one transaction, so it can't show two people acting at the same moment. These two tests can. Run them once, after `end-empty-tables.sql` and its verification have passed.

You need **two SQL Editor tabs** in the Supabase Dashboard, and **three test accounts** that you own and that aren't seated at any open table. Call them U1, U2 and U3, and copy their user ids from Authentication → Users.

How it works: Tab 1 starts a leave, then **holds its transaction open for 20 seconds** with `pg_sleep`, keeping its locks. While it waits, you run Tab 2. Tab 2 has to wait for Tab 1's lock, which is the whole point. Run Tab 2 within the 20 seconds.

Replace `U1`, `U2`, `U3` (the ids, kept in quotes) and `TABLE_ID` / `CODE` below with real values.

---

## Race 1: two people leave at once

**What it proves:** when the last two players leave at the same moment, the table still ends. Without the lock in the "end when empty" trigger, both could count one seat left, and neither would end it.

**Setup** (either tab, run once). It makes a 2-player table with U1 and U2 seated and shows its id and code:

```sql
with t as (
  insert into public.tables (code, created_by, is_public)
  select lpad(n::text, 4, '0'), 'U1'::uuid, false
  from generate_series(0, 9999) n
  where not exists (select 1 from public.tables x where x.code = lpad(n::text, 4, '0'))
  order by random()
  limit 1
  returning id, code
)
select id as table_id, code from t;
```

Then seat both, using the table id from that result:

```sql
insert into public.table_members (table_id, user_id) values ('TABLE_ID', 'U1');
insert into public.table_members (table_id, user_id) values ('TABLE_ID', 'U2');
```

**Tab 1.** U1 leaves and holds the transaction for 20 seconds:

```sql
begin;
select set_config('request.jwt.claims', json_build_object('sub', 'U1', 'role', 'authenticated')::text, true);
select public.leave_table('TABLE_ID');
select pg_sleep(20);
commit;
```

**Tab 2,** within those 20 seconds. U2 leaves:

```sql
begin;
select set_config('request.jwt.claims', json_build_object('sub', 'U2', 'role', 'authenticated')::text, true);
select public.leave_table('TABLE_ID');
commit;
```

**What you should see:** Tab 2 keeps running until Tab 1 finishes. It is waiting on the table's lock. Then both finish without errors.

**Check:**

```sql
select status, ended_reason,
       (select count(*) from public.table_members tm where tm.table_id = t.id) as seats
from public.tables t
where t.id = 'TABLE_ID';
```

**Pass:** `ended`, `empty`, `0`.
**Fail:** `open` with 0 seats. Neither leave ended it; paste this back.

---

## Race 2: someone joins just as the last player leaves

**What it proves:** nobody is ever seated at a table that has just ended. The seat trigger waits for the leave's lock, and then the "table must be open" trigger refuses the seat.

**Setup.** A fresh 2-player table with only U1 seated:

```sql
with t as (
  insert into public.tables (code, created_by, is_public)
  select lpad(n::text, 4, '0'), 'U1'::uuid, false
  from generate_series(0, 9999) n
  where not exists (select 1 from public.tables x where x.code = lpad(n::text, 4, '0'))
  order by random()
  limit 1
  returning id, code
)
select id as table_id, code from t;
```

```sql
insert into public.table_members (table_id, user_id) values ('TABLE_ID', 'U1');
```

**Tab 1.** U1, the only player, leaves and holds the transaction for 20 seconds:

```sql
begin;
select set_config('request.jwt.claims', json_build_object('sub', 'U1', 'role', 'authenticated')::text, true);
select public.leave_table('TABLE_ID');
select pg_sleep(20);
commit;
```

**Tab 2,** within those 20 seconds. U3 joins by the code:

```sql
begin;
select set_config('request.jwt.claims', json_build_object('sub', 'U3', 'role', 'authenticated')::text, true);
select * from public.join_table_by_code('CODE');
commit;
```

**What you should see:** Tab 2 keeps running until Tab 1 finishes, then shows the error **"This table has ended."** The join found the table open, then waited on the lock, and the new trigger refused the seat once the leave had committed. Hitting `outcome = not_found` instead is also a pass: it means Tab 2's lookup ran after Tab 1 committed, so try again faster if you want to see the error.

**Check:**

```sql
select status, ended_reason,
       (select count(*) from public.table_members tm where tm.table_id = t.id) as seats,
       exists (select 1 from public.table_members tm where tm.table_id = t.id and tm.user_id = 'U3') as u3_seated
from public.tables t
where t.id = 'TABLE_ID';
```

**Pass:** `ended`, `empty`, `0`, `false`.
**Fail:** `u3_seated = true`. Someone was seated at an ended table; paste this back.

---

## Cleanup

The two test tables are ended, which is harmless history. To remove them entirely:

```sql
delete from public.tables where id in ('TABLE_ID_FROM_RACE_1', 'TABLE_ID_FROM_RACE_2');
```

Their seats are already gone, and the delete cascades to anything left.
