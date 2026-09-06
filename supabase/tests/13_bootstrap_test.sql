-- ============================================================================
-- 13: Superadmin bootstrap — installing a faculty rep
-- ============================================================================
-- 0032. The top of the trust chain (TECHNICAL_DISCOVERY §2). Every level below
-- it already had an installer; this one was hand-written UPDATEs until now.
--
-- The assertion that matters most is §2's `email_verified_at` check. seed.sql
-- used to stamp that column when promoting its faculty reps, and copying it
-- here would have been the obvious thing to do — but 0019 DROPPED
-- mark_email_verified precisely to leave exactly one writer for that field.
-- A bootstrap function that stamps it re-opens the door 0019 closed, and no
-- other test in this suite would notice.
--
-- People used here:
--   ...001 Peter Kimani    already faculty_rep (FST) — idempotency + re-point
--   ...011 Mercy Wanjiku   class_rep — the non-student refusal
--   ...053 Ruth Nyaguthii  plain student, null email, SYNTHETIC auth address —
--                          given a real one below, for the email-copy path
--   ...054 Ian Maina       plain student, null email, synthetic auth address,
--                          left synthetic — proves it is NOT copied
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(22);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.fst_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.mercy()   returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;
create function pg_temp.ruth()    returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000053'::uuid $$;
create function pg_temp.ian()     returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000054'::uuid $$;
-- Plain student, but unlike the others she has a reg_number, a cohort AND an
-- oauth roster claim — the three things a promotion must not clobber.
create function pg_temp.faith()   returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000013'::uuid $$;

create function pg_temp.fst()  returns uuid language sql immutable as
  $$ select 'aaaaaaaa-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.fhss() returns uuid language sql immutable as
  $$ select 'aaaaaaaa-0000-4000-8000-000000000002'::uuid $$;

create function pg_temp.role_of(p_user uuid) returns text language sql stable as $$
  select role::text from users where id = p_user;
$$;
create function pg_temp.faculty_of(p_user uuid) returns uuid language sql stable as $$
  select faculty_id from users where id = p_user;
$$;
create function pg_temp.email_of(p_user uuid) returns text language sql stable as $$
  select email from users where id = p_user;
$$;
create function pg_temp.verified_of(p_user uuid) returns timestamptz language sql stable as $$
  select email_verified_at from users where id = p_user;
$$;
create function pg_temp.audit_count(p_user uuid) returns bigint language sql stable as $$
  select count(*) from role_audit_log where user_id = p_user and action = 'promoted';
$$;


-- ============================================================================
-- §1 Validation
-- ============================================================================
select throws_ok(
  $$ select bootstrap_faculty_rep(
       '22222222-0000-4000-8000-0000000000ff'::uuid,
       'aaaaaaaa-0000-4000-8000-000000000001'::uuid) $$,
  'P0001',
  'No such user: 22222222-0000-4000-8000-0000000000ff',
  'an unknown user id is refused'
);

select throws_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid,
             'aaaaaaaa-0000-4000-8000-0000000000ff'::uuid) $$, pg_temp.ruth()),
  'P0001',
  'No such faculty: aaaaaaaa-0000-4000-8000-0000000000ff',
  'an unknown faculty id is refused'
);

-- Same discipline as create_cohort_with_class_rep and promote_class_rep, and
-- the roles are exclusive by design: one person holds one role at a time. A
-- class rep moving up has to hand their cohort over first — otherwise the
-- promotion would silently strip that cohort's scheduling authority as a side
-- effect of an unrelated action. The error names the handover rather than just
-- refusing, because the assistant rep is usually the obvious successor.
select throws_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid, %L::uuid) $$,
         pg_temp.mercy(), pg_temp.fst()),
  'P0001',
  'Only a plain student account can be bootstrapped into a faculty rep; '
  'user 22222222-0000-4000-8000-000000000011 is currently class_rep. '
  'A sitting class rep must hand their cohort over first — demote_class_rep, '
  'then promote_class_rep for their successor (the assistant is the obvious '
  'one) — and can then be bootstrapped.',
  'a sitting class rep is refused, and told how to hand over'
);


-- ============================================================================
-- §2 The happy path, and the email it fills in
-- ============================================================================
-- Ruth arrives the way a real manually-onboarded rep does: created through
-- auth.users, so 0019's sync trigger built her public.users row — and skipped
-- the email, because that only happens for google/apple signups. Give her a
-- real institutional address on the auth side, which is what the Superadmin
-- would have used as her login identity.
update auth.users set email = 'r.nyaguthii@chuka.ac.ke' where id = pg_temp.ruth();

select lives_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid, %L::uuid) $$,
         pg_temp.ruth(), pg_temp.fhss()),
  'a plain student is installed as a faculty rep'
);

select is(pg_temp.role_of(pg_temp.ruth()), 'faculty_rep',
  'the role is set');

select is(pg_temp.faculty_of(pg_temp.ruth()), pg_temp.fhss(),
  'the faculty is anchored — this is what 0016 checks before letting them create a cohort');

select is(pg_temp.email_of(pg_temp.ruth()), 'r.nyaguthii@chuka.ac.ke',
  'the email the auth sync trigger skipped is filled in from auth.users');

-- THE ONE THAT MATTERS. This column has exactly one legitimate writer — the
-- OAuth path, from a provider-proven address. Stamping it here would re-open
-- the hole 0019 closed by dropping mark_email_verified.
select ok(
  pg_temp.verified_of(pg_temp.ruth()) is null,
  'email_verified_at is NOT stamped — nothing proved that address'
);

select is(pg_temp.audit_count(pg_temp.ruth()), 1::bigint,
  'installing a trust anchor leaves an audit row');

-- A FACULTY REP IS A STUDENT. Promotion adds responsibility; it does not
-- replace an identity. Faith is the fixture for this because she arrives with
-- all three things a promotion could plausibly clobber: a registration number,
-- a cohort, and an `oauth` roster claim. She must keep every one of them, and
-- go on seeing her cohort's timetable, because she goes on attending it.
--
-- This is asserted rather than assumed because the repo believed the opposite
-- until 2026-08-24: seed.sql §8 modelled faculty reps as Deans on staff
-- addresses (corrected), and 0002's reg_number comment still says they have no
-- registration number (applied history, flagged in TECHNICAL_DISCOVERY §10).
select lives_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid, %L::uuid) $$,
         pg_temp.faith(), pg_temp.fst()),
  'a student with a cohort and a claimed roster row can be made a faculty rep'
);

select is(
  (select reg_number from users where id = pg_temp.faith()),
  'EB1/67340/23',
  '...and KEEPS their registration number — they are still a student'
);

select ok(
  (select cohort_id from users where id = pg_temp.faith()) is not null,
  '...keeps their cohort, so they still see the timetable they still attend'
);

select is(
  (select claim_method::text from student_roster where claimed_by = pg_temp.faith()),
  'oauth',
  '...and their roster claim survives untouched'
);

select is(
  (select snapshot ->> 'actor' from role_audit_log
     where user_id = pg_temp.ruth() and action = 'promoted'),
  'superadmin',
  'the audit row names the superadmin — a null actor_id here is honest, not lossy'
);


-- ============================================================================
-- §3 A synthetic reg-number address is never copied
-- ============================================================================
-- Ian's auth identity is eb3.72010.26@auth.internal. That address is an
-- implementation detail of auth.users (0002) and must never reach
-- public.users.email. A faculty rep on the reg-number path is a mistake
-- upstream of here; this refuses to record its artefact.
select lives_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid, %L::uuid) $$,
         pg_temp.ian(), pg_temp.fst()),
  'a student whose auth identity is synthetic still bootstraps'
);

select is(pg_temp.role_of(pg_temp.ian()), 'faculty_rep',
  '...the role is still set');

select ok(
  pg_temp.email_of(pg_temp.ian()) is null,
  '...but the synthetic @auth.internal address is NOT copied into public.users'
);


-- ============================================================================
-- §4 Idempotency, and the re-point that is not idempotent
-- ============================================================================
-- A bootstrap procedure gets run twice — by someone unsure the first attempt
-- landed, or by two people onboarding the same dean.
select lives_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid, %L::uuid) $$,
         pg_temp.fst_rep(), pg_temp.fst()),
  're-running against the SAME faculty is a no-op, not an error'
);

select is(pg_temp.audit_count(pg_temp.fst_rep()), 0::bigint,
  '...and writes no second audit row, because it returns before the insert'
);

-- Moving a trust anchor is a different operation. Cohorts created under the
-- old faculty would be left scoped to a rep who can no longer administer them.
select throws_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid, %L::uuid) $$,
         pg_temp.fst_rep(), pg_temp.fhss()),
  'P0001',
  'User 22222222-0000-4000-8000-000000000001 is already the faculty rep for a '
  'different faculty (aaaaaaaa-0000-4000-8000-000000000001). '
  'Re-pointing a faculty rep is not a bootstrap operation.',
  're-pointing an existing faculty rep at another faculty is refused'
);

select is(pg_temp.faculty_of(pg_temp.fst_rep()), pg_temp.fst(),
  '...and leaves them anchored where they were'
);


-- ============================================================================
-- §5 Access control
-- ============================================================================
-- This creates the role every other role's authority descends from. A faculty
-- rep who could call it could mint peers.
set local role authenticated;
select pg_temp.act_as(pg_temp.fst_rep());

select throws_ok(
  format($$ select bootstrap_faculty_rep(%L::uuid, %L::uuid) $$,
         pg_temp.ian(), pg_temp.fst()),
  '42501',
  'permission denied for function bootstrap_faculty_rep',
  'not even a sitting faculty rep may call it — service_role only'
);

reset role;


select * from finish();
rollback;
