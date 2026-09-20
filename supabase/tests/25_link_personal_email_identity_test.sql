-- ============================================================================
-- 25: link_personal_email_identity (0046)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §6: an oauth (school-email) account links a personal
-- address as a recovery contact for after the school address stops working.
-- Unconditional — no rep, no derivation, no identity fields touched. Explicit
-- product decision (this plan): re-linking a different address OVERWRITES
-- personal_email rather than refusing, with an audit row capturing the
-- previous address.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

-- A fresh school-email OAuth signup (Flow 2's trigger path, 0039): claim_method
-- starts null, becomes 'oauth' only once approved into a cohort. For this
-- function's guard (claim_method = 'oauth'), force-set it directly, the same
-- way earlier plans' tests reach otherwise-unreachable states without a full
-- approval flow (see 06/21/22's precedent).
create function pg_temp.new_oauth_signup(p_id uuid, p_email text) returns void
language plpgsql as $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, email_change,
    email_change_token_new, recovery_token
  )
  values (
    '00000000-0000-0000-0000-000000000000',
    p_id, 'authenticated', 'authenticated',
    p_email, 'x', now(), now(),
    jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
    jsonb_build_object('first_name', 'Test', 'last_name', 'Account'),
    now(), now(), '', '', '', ''
  );

  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
end;
$$;

-- Simulates a successful linkIdentity() call: a second auth.identities row
-- for the same user_id, a different address. created_at/updated_at have no
-- column default (confirmed against the running local instance) and
-- link_personal_email_identity orders by created_at desc to pick the
-- most-recently-linked candidate -- clock_timestamp() (not now(), which is
-- frozen for the whole transaction these tests run in) is what makes that
-- ordering actually mean something across sequential calls.
create function pg_temp.link_identity(p_id uuid, p_email text) returns void
language sql as $$
  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_email, p_id, jsonb_build_object('sub', p_email, 'email', p_email), 'google', clock_timestamp(), clock_timestamp());
$$;


-- ---------------------------------------------------------------------------
-- §1 First link: an oauth account with no personal_email yet.
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '99999999-0000-4000-8000-000000000001', 'eb1.99101.26@student.chuka.ac.ke'
);
update users set claim_method = 'oauth' where id = '99999999-0000-4000-8000-000000000001';
select ok(
  (select personal_email from users where id = '99999999-0000-4000-8000-000000000001') is null,
  'sanity: no personal_email yet'
);

select pg_temp.act_as('99999999-0000-4000-8000-000000000001');
select pg_temp.link_identity(
  '99999999-0000-4000-8000-000000000001', 'first.recovery@gmail.com'
);
select lives_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000001'::uuid) $$,
  'linking a personal email for the first time succeeds'
);
select is(
  (select personal_email from users where id = '99999999-0000-4000-8000-000000000001'),
  'first.recovery@gmail.com',
  '...personal_email is recorded'
);
select ok(
  (select personal_email_verified_at from users where id = '99999999-0000-4000-8000-000000000001') is not null,
  '...personal_email_verified_at is stamped'
);
select is(
  (select action::text from identity_audit_log
   where target_user = '99999999-0000-4000-8000-000000000001' and actor_id = '99999999-0000-4000-8000-000000000001'
   order by created_at desc limit 1),
  'identity_linked',
  '...an identity_linked audit row is written'
);


-- ---------------------------------------------------------------------------
-- §2 Re-link a different address: overwrite (explicit product decision),
-- with the previous address preserved in the audit row's snapshot.
-- ---------------------------------------------------------------------------
select pg_temp.link_identity(
  '99999999-0000-4000-8000-000000000001', 'second.recovery@gmail.com'
);
select lives_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000001'::uuid) $$,
  're-linking a different personal email succeeds (overwrite, not refuse)'
);
select is(
  (select personal_email from users where id = '99999999-0000-4000-8000-000000000001'),
  'second.recovery@gmail.com',
  '...personal_email now holds the new address'
);
-- Two identity_linked audit rows now exist for this target_user/actor_id
-- (from §1 and this call), and created_at has no tiebreaker here -- now()
-- is frozen for this whole transaction, so both rows share one timestamp
-- and "order by created_at desc" cannot distinguish them. Identify this
-- call's row by its own snapshot content instead.
select is(
  (select (snapshot ->> 'previous_personal_email') from identity_audit_log
   where target_user = '99999999-0000-4000-8000-000000000001' and actor_id = '99999999-0000-4000-8000-000000000001'
     and snapshot ->> 'new_personal_email' = 'second.recovery@gmail.com'),
  'first.recovery@gmail.com',
  '...the audit row''s snapshot preserves the superseded address'
);


-- ---------------------------------------------------------------------------
-- §3 Guards
-- ---------------------------------------------------------------------------
select pg_temp.new_oauth_signup(
  '99999999-0000-4000-8000-000000000002', 'not.oauth.yet@gmail.com'
);
-- claim_method left null -- a fresh signup that has not yet been approved
-- into anything, the state this guard must refuse.
select pg_temp.act_as('99999999-0000-4000-8000-000000000002');
select pg_temp.link_identity(
  '99999999-0000-4000-8000-000000000002', 'wontmatter@gmail.com'
);
select throws_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000002'::uuid) $$,
  'P0001',
  'Only a school-email-verified account can link a personal email as a recovery contact',
  'an account that is not yet claim_method = oauth cannot use this path'
);

select throws_ok(
  $$ select link_personal_email_identity('11111111-0000-4000-8000-000000000099'::uuid) $$,
  'P0001',
  'p_actor_id must match the calling user',
  'the acting-user parameter must match auth.uid()'
);

select pg_temp.new_oauth_signup(
  '99999999-0000-4000-8000-000000000003', 'eb1.99103.26@student.chuka.ac.ke'
);
update users set claim_method = 'oauth' where id = '99999999-0000-4000-8000-000000000003';
select pg_temp.act_as('99999999-0000-4000-8000-000000000003');
select throws_ok(
  $$ select link_personal_email_identity('99999999-0000-4000-8000-000000000003'::uuid) $$,
  'P0001',
  'No linked personal-email identity was found for this account',
  'calling this before linkIdentity() has actually succeeded is refused'
);

select * from finish();
rollback;
