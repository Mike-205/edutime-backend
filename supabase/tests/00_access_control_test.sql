-- ============================================================================
-- 00: Access control — the structural invariants
-- ============================================================================
-- These are the cheapest and most valuable tests in the suite, because they
-- assert things that are true or false about the schema itself, with no fixtures
-- and no workflow. Two of them would have caught bugs that shipped through
-- thirteen migrations unnoticed:
--
--   * "authenticated can SELECT every public table" — 0001-0013 enabled RLS and
--     wrote policies but never GRANTed anything, so every client query failed
--     with 42501 before RLS was consulted. Policies and privileges are separate
--     mechanisms and both are required.
--   * "every public table has RLS enabled" — `faculties` never got it.
--
-- Run: supabase test db
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(26);


-- ---------------------------------------------------------------------------
-- RLS coverage
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity),
  0,
  'every public table has RLS enabled'
);

-- RLS on with no policy is worse than RLS off: the table becomes invisible to
-- everyone except the owner, silently, with nothing in the logs.
select is(
  (select count(*)::int
   from pg_tables t
   where t.schemaname = 'public'
     and t.rowsecurity
     and not exists (
       select 1 from pg_policies p
       where p.schemaname = 'public' and p.tablename = t.tablename
     )),
  0,
  'no table has RLS enabled but zero policies'
);


-- ---------------------------------------------------------------------------
-- Table privileges
-- ---------------------------------------------------------------------------
-- anon must hold nothing at all. Every policy requires auth.uid() to be
-- non-null so anon could never read a row anyway, but TRUNCATE — which the
-- inherited default ACL granted — ignores RLS entirely.
select is(
  (select count(*)::int
   from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'anon'),
  0,
  'anon holds no table privileges whatsoever'
);

-- users is the one deliberate exception (0043): it holds no table-level
-- SELECT bit at all any more, only a column-level grant on a safe subset,
-- so has_table_privilege(..., 'select') correctly reads false for it even
-- though authenticated can still read part of every row.
select is(
  (select count(*)::int
   from pg_tables
   where schemaname = 'public'
     and tablename != 'users'
     and not has_table_privilege('authenticated', schemaname || '.' || tablename, 'select')),
  0,
  'authenticated can SELECT every public table except users, which is column-restricted (0043)'
);


-- ---------------------------------------------------------------------------
-- The scheduling tables are read-only to clients
-- ---------------------------------------------------------------------------
-- Every mutation goes through a SECURITY DEFINER function (0010 §12). A direct
-- INSERT or UPDATE privilege here would reopen the path those functions replaced.
select ok(
  not has_table_privilege('authenticated', 'public.events', 'insert'),
  'events is not client-insertable'
);
select ok(
  not has_table_privilege('authenticated', 'public.events', 'update'),
  'events is not client-updatable'
);
select ok(
  not has_table_privilege('authenticated', 'public.event_cohorts', 'insert'),
  'event_cohorts is not client-insertable'
);
select ok(
  not has_table_privilege('authenticated', 'public.event_audit_log', 'insert'),
  'event_audit_log is append-only from the server side'
);
-- Same reasoning for the role audit trail (0022 §5). A forged 'promoted' row
-- would make the record of who granted scheduling authority worthless.
select ok(
  not has_table_privilege('authenticated', 'public.role_audit_log', 'insert'),
  'role_audit_log is append-only from the server side'
);


-- ---------------------------------------------------------------------------
-- Column-level privileges: the privilege layer half of the self-promotion fix
-- ---------------------------------------------------------------------------
-- RLS cannot restrict columns, only rows. These grants are what stop a student
-- writing their own role, and Postgres checks them before any trigger runs.
select ok(
  has_column_privilege('authenticated', 'public.users', 'first_name', 'update'),
  'a user may update their own first_name'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'role', 'update'),
  'a user may NOT update users.role (self-promotion)'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'cohort_id', 'update'),
  'a user may NOT update users.cohort_id (join any cohort at will)'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'class_rep_rank', 'update'),
  'a user may NOT update users.class_rep_rank'
);

select ok(
  has_column_privilege('authenticated', 'public.notifications', 'read_at', 'update'),
  'a user may mark their own notification read'
);
select ok(
  not has_column_privilege('authenticated', 'public.notifications', 'message', 'update'),
  'a user may NOT rewrite a notification the server generated'
);


-- ---------------------------------------------------------------------------
-- users: column-level SELECT hardening (0043)
-- ---------------------------------------------------------------------------
-- 0006's users_read_all policy filters no rows (auth.uid() is not null),
-- so the privilege layer is the ONLY thing standing between a student and
-- every other student's identity columns. Directory fields stay readable
-- cross-account; identity/contact fields are select-granted to nobody but
-- the row's own owner via current_app_user() (a SECURITY DEFINER RPC, not
-- a table grant).
select ok(
  has_column_privilege('authenticated', 'public.users', 'first_name', 'select'),
  'a user may read another user''s first_name (directory listing)'
);
select ok(
  has_column_privilege('authenticated', 'public.users', 'cohort_id', 'select'),
  'a user may read another user''s cohort_id (directory listing)'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'email', 'select'),
  'a user may NOT read another user''s personal contact email'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'school_email', 'select'),
  'a user may NOT read another user''s school_email'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'personal_email', 'select'),
  'a user may NOT read another user''s personal_email'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'reg_number', 'select'),
  'a user may NOT read another user''s reg_number'
);
select ok(
  not has_column_privilege('authenticated', 'public.users', 'student_number', 'select'),
  'a user may NOT read another user''s student_number'
);
select ok(
  has_function_privilege('authenticated', 'current_app_user()', 'execute'),
  'a user can still read their OWN full row via current_app_user()'
);


-- ---------------------------------------------------------------------------
-- Realtime channel authorization
-- ---------------------------------------------------------------------------
-- The triggers broadcast with private => true, which makes every subscribe
-- authorize against RLS on realtime.messages. With no policy the channels in §9
-- of TECHNICAL_DISCOVERY are unsubscribable.
select isnt_empty(
  $$ select 1 from pg_policies where schemaname = 'realtime' and tablename = 'messages' $$,
  'realtime.messages has an authorization policy'
);


-- ---------------------------------------------------------------------------
-- Function hardening
-- ---------------------------------------------------------------------------
-- An unpinned search_path on a SECURITY DEFINER function is a privilege
-- escalation vector: the caller controls which schema its unqualified
-- identifiers resolve to. 0008 pinned these; this stops a new one regressing.
select is(
  (select count(*)::int
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and not exists (
       select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%'
     )),
  0,
  'every SECURITY DEFINER function in public pins its search_path'
);

-- Regression test for the REVOKE that did nothing. CREATE FUNCTION implicitly
-- grants EXECUTE to PUBLIC, and a privilege held via PUBLIC cannot be revoked
-- from one role — so every `revoke execute ... from anon` in 0008/0010/0012/0013
-- was a no-op and anon kept EXECUTE the whole time.
select is(
  (select count(*)::int
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in (
       'create_event', 'cancel_event', 'confirm_event_cohort', 'decline_event_cohort',
       'leave_event_cohort', 'reschedule_event', 'get_venue_occupancy',
       'is_venue_available', 'create_cohort_with_class_rep', 'demote_class_rep',
       'approve_cohort_join_request', 'decline_cohort_join_request',
       'parse_reg_number', 'normalize_reg_number', 'reg_number_from_email',
       -- Phase 1 (0022). Every one of these mutates a schedule or a role, so
       -- every one of them must be closed to anon the moment it is created —
       -- CREATE FUNCTION grants EXECUTE to PUBLIC, so the revoke is not optional.
       'cancel_recurrence_group', 'update_event',
       'confirm_attendance', 'unconfirm_attendance', 'promote_class_rep',
       'resolve_identity_dispute'
     )
     and has_function_privilege('anon', p.oid, 'execute')),
  0,
  'anon cannot execute any privileged RPC'
);


select * from finish();
rollback;
