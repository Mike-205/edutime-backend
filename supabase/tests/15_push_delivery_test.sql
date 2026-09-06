-- ============================================================================
-- 15: Push delivery (FCM) — 0034, TODO 3.1
-- ============================================================================
-- Covers the SQL half only: register_device_token()'s token-reassignment
-- rule and claim_pending_pushes()'s claim/stamp/idempotency behaviour. The
-- actual FCM send (functions/dispatch-push, _shared/fcm.ts) needs a real
-- device token from a Flutter client that doesn't exist yet, so it isn't
-- exercised here — see TECHNICAL_DISCOVERY §11.
--
-- People used (plain students, seed.sql §8):
--   ...012 first claimant
--   ...015 second claimant — reassignment target
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(16);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.user_a() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000012'::uuid $$;
create function pg_temp.user_b() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000015'::uuid $$;

create function pg_temp.token_owner(p_token text) returns uuid language sql stable as $$
  select user_id from device_tokens where token = p_token;
$$;


-- ---------------------------------------------------------------------------
-- §1 register_device_token — claim, re-claim, reassignment
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.act_as(pg_temp.user_a());

select lives_ok(
  $$ select register_device_token('tok-shared-phone', 'android') $$,
  'user A registers a token'
);
select is(pg_temp.token_owner('tok-shared-phone'), pg_temp.user_a(),
  'the token is owned by user A');

-- Re-registering the same token for the same user must not error or duplicate.
select lives_ok(
  $$ select register_device_token('tok-shared-phone', 'android') $$,
  're-registering the same token for the same user is idempotent'
);
select is(
  (select count(*)::int from device_tokens where token = 'tok-shared-phone'),
  1,
  'still exactly one row for that token'
);

-- The phone changes hands — user B installs the app and gets the same FCM
-- registration token. This must move ownership, not create a second row.
select pg_temp.act_as(pg_temp.user_b());
select lives_ok(
  $$ select register_device_token('tok-shared-phone', 'android') $$,
  'user B registers the SAME token (device resold/reissued)'
);
select is(pg_temp.token_owner('tok-shared-phone'), pg_temp.user_b(),
  'ownership moved to user B');
select is(
  (select count(*)::int from device_tokens where token = 'tok-shared-phone'),
  1,
  'still exactly one row — the old claim was deleted, not left behind'
);
select is(
  (select count(*)::int from device_tokens where user_id = pg_temp.user_a()),
  0,
  'user A has no device token left after losing the phone'
);

reset role;


-- ---------------------------------------------------------------------------
-- §2 claim_pending_pushes — claim, stamp, idempotency, device-less users
-- ---------------------------------------------------------------------------
-- A notification for a user WITH a device token.
insert into notifications (id, user_id, title, message, type)
values ('33333333-0000-4000-8000-000000000001', pg_temp.user_b(), 'Test', 'body', 'created');

-- A notification for a user with NO device token at all.
insert into notifications (id, user_id, title, message, type)
values ('33333333-0000-4000-8000-000000000002', pg_temp.user_a(), 'Test', 'body', 'created');

select is(
  (select count(*)::int from claim_pending_pushes(500)
   where notification_id = '33333333-0000-4000-8000-000000000001'),
  1,
  'the device-holding user''s notification is returned for dispatch'
);

select is(
  (select pushed_at is not null from notifications
   where id = '33333333-0000-4000-8000-000000000001'),
  true,
  'that notification is stamped pushed_at'
);

select is(
  (select pushed_at is not null from notifications
   where id = '33333333-0000-4000-8000-000000000002'),
  true,
  'the device-less user''s notification is ALSO stamped, so it never gets '
  'reselected forever (0034 §3''s comment)'
);

select is(
  (select count(*)::int from claim_pending_pushes(500)
   where notification_id in (
     '33333333-0000-4000-8000-000000000001', '33333333-0000-4000-8000-000000000002'
   )),
  0,
  'a second claim returns neither notification — both already stamped'
);


-- ---------------------------------------------------------------------------
-- §3 Access control
-- ---------------------------------------------------------------------------
select ok(
  not has_table_privilege('authenticated', 'public.device_tokens', 'insert'),
  'device_tokens is not client-insertable — register_device_token is the only writer'
);
select ok(
  not has_function_privilege('authenticated', 'claim_pending_pushes(int)', 'execute'),
  'authenticated cannot call claim_pending_pushes — service_role only'
);
select ok(
  not has_function_privilege('anon', 'register_device_token(text, device_platform)', 'execute'),
  'anon cannot call register_device_token'
);
-- Regression guard: notifications_mark_read_own (0006) is a table-wide
-- UPDATE policy, but RLS cannot restrict columns — only the explicit
-- column-scoped grant does. If a future migration ever widens that grant to
-- the whole row, a client could stamp/clear their own pushed_at to suppress
-- or force-resend their own pushes.
select ok(
  not has_column_privilege('authenticated', 'public.notifications', 'pushed_at', 'update'),
  'a user may NOT write notifications.pushed_at (push-suppression via self-update)'
);

select * from finish();
rollback;
