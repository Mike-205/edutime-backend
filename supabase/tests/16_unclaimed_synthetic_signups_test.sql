-- ============================================================================
-- 16: Unclaimed synthetic-signup diagnostic — 0036, TODO 4.4
-- ============================================================================
-- Covers unclaimed_synthetic_signups(): the grace period, the "claimed
-- accounts never appear" exclusion, and access control (faculty-rep only,
-- not scoped to a specific faculty since an unclaimed account has none).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

-- A faculty rep already in the seed dataset (own faculty irrelevant here —
-- the function isn't scoped to one).
create function pg_temp.faculty_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;
-- A plain student — used to prove access control.
create function pg_temp.plain_student() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000012'::uuid $$;

-- Stuck for two hours: past the 1-hour grace period, never claimed.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '22222222-0000-4000-8000-0000000000fa', 'authenticated', 'authenticated',
  'stuck.case@auth.internal', 'x', now() - interval '2 hours', now(),
  jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
  jsonb_build_object('first_name', 'Stuck', 'last_name', 'Case'),
  now() - interval '2 hours', now(), '', '', '', ''
);
update users set created_at = now() - interval '2 hours'
  where id = '22222222-0000-4000-8000-0000000000fa';

-- Signed up 5 minutes ago: still inside the grace period, mid-flow.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '22222222-0000-4000-8000-0000000000fb', 'authenticated', 'authenticated',
  'fresh.case@auth.internal', 'x', now() - interval '5 minutes', now(),
  jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
  jsonb_build_object('first_name', 'Fresh', 'last_name', 'Case'),
  now() - interval '5 minutes', now(), '', '', '', ''
);
update users set created_at = now() - interval '5 minutes'
  where id = '22222222-0000-4000-8000-0000000000fb';


-- ---------------------------------------------------------------------------
-- §1 Content
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.faculty_rep());

select isnt_empty(
  $$ select 1 from unclaimed_synthetic_signups()
     where user_id = '22222222-0000-4000-8000-0000000000fa' $$,
  'an account stuck unclaimed past the grace period is surfaced'
);
select is(
  (select synthetic_email from unclaimed_synthetic_signups()
   where user_id = '22222222-0000-4000-8000-0000000000fa'),
  'stuck.case@auth.internal',
  'the synthetic email is exposed as-is, for comparing against what the client actually built'
);
select is_empty(
  $$ select 1 from unclaimed_synthetic_signups()
     where user_id = '22222222-0000-4000-8000-0000000000fb' $$,
  'an account 5 minutes old is still inside the grace period — not flagged as stuck'
);
select is_empty(
  $$ select 1 from unclaimed_synthetic_signups()
     where user_id = (select claimed_by from student_roster where reg_number = 'EB1/67277/23') $$,
  'a successfully claimed account never appears, however old the signup'
);

reset role;


-- ---------------------------------------------------------------------------
-- §2 Access control
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.plain_student());

select is_empty(
  $$ select 1 from unclaimed_synthetic_signups() $$,
  'a plain student sees nothing — not faculty_rep, not merely unauthenticated'
);

reset role;

select ok(
  not has_function_privilege('anon', 'unclaimed_synthetic_signups()', 'execute'),
  'anon cannot call unclaimed_synthetic_signups at all'
);
select ok(
  has_function_privilege('authenticated', 'unclaimed_synthetic_signups()', 'execute'),
  'authenticated holds EXECUTE — the inline exists() check is what actually gates rows'
);

select * from finish();
rollback;
