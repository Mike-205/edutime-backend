-- ============================================================================
-- 18: claim_method column on users (0038)
-- ============================================================================
-- Covers AUTH_FLOW_REFACTOR.md §2's rule that claim_method is the only
-- column any access decision reads. This migration adds the column and
-- extends guard_users_self_update to it, ahead of any function writing it —
-- same structure-first discipline as 17_identity_schema_test.sql.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;
-- Same fixture id 05_roster_test.sql / 17_identity_schema_test.sql use.
create function pg_temp.student() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;


-- ---------------------------------------------------------------------------
-- §1 The column exists, reuses the existing claim_method enum
-- ---------------------------------------------------------------------------
select lives_ok(
  format($$ update users set claim_method = 'provisional' where id = %L $$, pg_temp.student()),
  'claim_method accepts a valid value of the existing enum'
);

select throws_ok(
  format($$ update users set claim_method = 'bogus' where id = %L $$, pg_temp.student()),
  '22P02', null,
  'claim_method rejects a value outside the existing enum'
);


-- ---------------------------------------------------------------------------
-- §2 Not client-writable
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.student());

select throws_ok(
  $$ update users set claim_method = 'oauth' where id = auth.uid() $$,
  '42501', null, 'a student cannot set their own claim_method directly'
);

select lives_ok(
  $$ update users set first_name = 'Renamed' where id = auth.uid() $$,
  'a student can still edit their own display name — the guard extension did not regress the allowed path'
);

reset role;

select * from finish();
rollback;
