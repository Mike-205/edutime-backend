-- ============================================================================
-- 0032: Superadmin bootstrap — installing a faculty rep (3.5)
-- ============================================================================
-- Implements TODO §3.5. The trust chain (TECHNICAL_DISCOVERY §2) is
-- `Superadmin -> Faculty Rep -> Class Rep -> Student`, and every level below
-- the first has a function that installs it: create_cohort_with_class_rep and
-- promote_class_rep install class reps, claim_roster_row places students. The
-- TOP of the chain had nothing. Faculty rep onboarding was "manual and
-- out-of-band" with no procedure at all, so the one role that anchors every
-- other one was the only role installed by hand-written UPDATEs.
--
-- WHAT ACTUALLY BREAKS WITHOUT THIS, precisely — TODO §3.5 says a manually
-- created faculty rep has "a NULL email and a NULL faculty_id, which after 0014
-- means they can do nothing at all". The faculty_id half is exact:
-- `0016` raises *"This faculty_rep has no faculty_id set and cannot create
-- cohorts"* (and the same for demote). The email half is not — no authority
-- check reads `users.email` at all. It is contact information, and worth
-- filling in for that reason, but it is `faculty_id` that makes the difference
-- between a working trust anchor and an inert one.
--
-- WHY A FUNCTION AND NOT A SHELL SCRIPT. §3.5 asked for "a real script or
-- documented runbook". A definer function is the mechanism the runbook
-- describes rather than a replacement for it (the runbook is
-- TECHNICAL_DISCOVERY §14): it is testable in pgTAP the way §4.2 requires,
-- which a shell script is not, and it puts the validation in one place instead
-- of in whoever's terminal history. `request_password_recovery` (0031) is the
-- existing precedent for a service_role-only definer function.
--
-- A FACULTY REP IS A STUDENT. This is the part easiest to get wrong, and the
-- repo got it wrong before this migration. Class rep and faculty rep are not
-- separate kinds of person — they are students carrying more responsibility,
-- with the same @student university address and the same registration number
-- they had before. DISCOVERY says only that a class rep is "a student elevated
-- by a Faculty Rep" and never describes a faculty rep as staff; the idea that
-- they are Deans on @chuka.ac.ke addresses with no registration number was an
-- assumption seed.sql introduced and 0002's `reg_number` comment then repeated.
--
-- What follows from it, and why this function is shaped the way it is:
--   * It sets `role` and `faculty_id` and NOTHING else. `reg_number`,
--     `cohort_id` and the student's claimed roster row are all left untouched,
--     because promotion adds responsibility rather than replacing an identity.
--     Verified: a promoted student keeps all three, and their `oauth` roster
--     claim survives intact.
--   * A faculty rep therefore still belongs to a cohort and still sees its
--     timetable as a student — which is correct, since they still attend it.
--   * The reg-number/password signup path is as ordinary for a faculty rep as
--     for anyone else. Nothing here treats it as anomalous.
--
-- HOW IT GETS PAST THE GUARD, and why that is deliberate rather than a hole:
-- `guard_users_self_update` (0014 §2) blocks direct writes to `role`,
-- `faculty_id` and `email`, but short-circuits on
-- `current_user not in ('authenticated', 'anon')`. A SECURITY DEFINER function
-- owned by postgres therefore walks straight past it — which is exactly why
-- this function has to do its own validation. Nothing downstream will.
-- ============================================================================


-- ============================================================================
-- 1. bootstrap_faculty_rep
-- ============================================================================
-- Superadmin only. The Superadmin is not a `user_role` value and has no row in
-- `users` (TECHNICAL_DISCOVERY §10) — it is the service_role key. So there is
-- no `p_acting_user` to check against auth.uid() the way every other
-- privileged function does; holding the key IS the authorization, and the
-- grant at the bottom of this file is the whole of it.
--
-- Consequently `role_audit_log.actor_id` is null for these rows. That is
-- honest rather than lossy: there is no user to name. The snapshot records
-- 'superadmin' so a null actor here is distinguishable from a null actor
-- caused by 2.3's `on delete set null`.
--
-- EMAIL_VERIFIED_AT IS DELIBERATELY NOT SET. seed.sql §8 used to stamp it when
-- promoting its faculty reps, and copying that would have been wrong twice
-- over: the seed is the institution fabricating a starting state while this
-- runs against a live deployment, and §10's rule is that `email_verified_at`
-- may only ever be written from a provider-proven address. `mark_email_verified`
-- was DROPPED in 0019 specifically to remove the second way to set it, so
-- stamping it here would re-open that door. (The seed no longer stamps it
-- either — its faculty reps are OAuth signups now, so the trigger does.)
--
-- Nothing is gained by stamping it, either. The only functional read of the
-- column is `claim_roster_row` (0019) deciding oauth-vs-provisional — and a
-- faculty rep, being a student, has already claimed their roster row by the
-- time this runs, at signup, with whatever method was honest then. Setting the
-- column afterwards would not revisit that claim; it would only fake the one
-- trust signal §10 says is meaningful. Verification is a badge, not a gate
-- (§2), and a rep who signed in with Google already has it set correctly by
-- `handle_new_auth_user`.
create or replace function bootstrap_faculty_rep(
  p_user_id    uuid,
  p_faculty_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user       users;
  v_auth_email text;
  v_name       text;
begin
  select * into v_user from users where id = p_user_id;

  if v_user.id is null then
    raise exception 'No such user: %', p_user_id;
  end if;

  if not exists (select 1 from faculties where id = p_faculty_id) then
    raise exception 'No such faculty: %', p_faculty_id;
  end if;

  -- Idempotent for a re-run against the same faculty. A bootstrap procedure
  -- gets run twice — by the same person unsure whether the first attempt
  -- landed, or by two people onboarding the same person. Re-pointing an existing
  -- faculty rep at a DIFFERENT faculty is a different operation entirely and
  -- is refused: it would move a trust anchor silently, leaving cohorts created
  -- under the old faculty scoped to a rep who can no longer administer them.
  if v_user.role = 'faculty_rep' then
    if v_user.faculty_id = p_faculty_id then
      return;
    end if;
    raise exception
      'User % is already the faculty rep for a different faculty (%). '
      'Re-pointing a faculty rep is not a bootstrap operation.',
      p_user_id, v_user.faculty_id;
  end if;

  -- Same discipline as create_cohort_with_class_rep and promote_class_rep:
  -- only a plain student is promotable. Promoting a sitting class_rep would
  -- strip their cohort's scheduling authority as a side effect of an unrelated
  -- action, and leave `class_rep_rank` set on a non-class_rep — which
  -- `users_rank_only_for_class_rep` would then reject anyway, but with a
  -- constraint violation instead of a sentence.
  if v_user.role <> 'student' then
    raise exception
      'Only a plain student account can be bootstrapped into a faculty rep; '
      'user % is currently %. A sitting class rep must hand their cohort over '
      'first — demote_class_rep, then promote_class_rep for their successor '
      '(the assistant is the obvious one) — and can then be bootstrapped.',
      p_user_id, v_user.role;
  end if;

  -- The sync trigger (0019) only copies an address into public.users for
  -- google/apple signups, so a rep who signed up on the reg-number/password
  -- path arrives with a null one. Fill it from the auth identity — but never
  -- with a synthetic reg-number address, which must not leak into
  -- public.users.email (0002, 0019). That rule is about the synthetic address
  -- itself and applies to every role equally; a faculty rep on the password
  -- branch is entirely ordinary (see the note on identity above), and their
  -- real university address arrives the same way any student's does, through
  -- OAuth.
  select email into v_auth_email from auth.users where id = p_user_id;

  if v_user.email is null
     and v_auth_email is not null
     and v_auth_email not like '%@auth.internal' then
    update users set email = v_auth_email where id = p_user_id;
  end if;

  update users
    set role       = 'faculty_rep',
        faculty_id = p_faculty_id
    where id = p_user_id;

  v_name := trim(coalesce(v_user.first_name, '') || ' ' || coalesce(v_user.last_name, ''));

  -- Installing a trust anchor is the single most consequential role change in
  -- this schema, and §0.5's rule about manual overrides applies with full
  -- force: an unlogged one would be the most dangerous function here.
  insert into role_audit_log (user_id, user_name, cohort_id, action, new_rank, actor_id, snapshot)
  values (
    p_user_id, v_name, null, 'promoted', null, null,
    jsonb_build_object(
      'actor',         'superadmin',
      'previous_role', v_user.role,
      'faculty_id',    p_faculty_id,
      'new_role',      'faculty_rep'
    )
  );
end;
$$;

comment on function bootstrap_faculty_rep(uuid, uuid) is
  'Superadmin only (service_role key). Installs a plain student account as a '
  'faculty rep anchored to one faculty, filling the email the auth sync '
  'trigger skips for non-OAuth signups. Idempotent for the same faculty, '
  'refused for a different one. Deliberately does not touch '
  'email_verified_at — see 0019, that field has exactly one legitimate writer.';


-- ============================================================================
-- 2. guard_users_self_update names a function that no longer exists
-- ============================================================================
-- Its error message has told users to change their email "via
-- mark_email_verified" since 0014 — and 0019 DROPPED that function rather than
-- hardening it (TODO §1.5). So the one message a user sees when they hit this
-- guard directs them at something that has not existed for thirteen
-- migrations. Body is otherwise unchanged.
--
-- CREATE OR REPLACE discards proconfig, so `set search_path = public` has to be
-- restated — the trap 0019 recorded after it silently un-pinned
-- handle_new_auth_user and re-opened 0008's escalation vector.
create or replace function guard_users_self_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return NEW;
  end if;

  if NEW.id                is distinct from OLD.id
  or NEW.role              is distinct from OLD.role
  or NEW.class_rep_rank    is distinct from OLD.class_rep_rank
  or NEW.cohort_id         is distinct from OLD.cohort_id
  or NEW.reg_number        is distinct from OLD.reg_number
  or NEW.email             is distinct from OLD.email
  or NEW.email_verified_at is distinct from OLD.email_verified_at
  or NEW.faculty_id        is distinct from OLD.faculty_id
  or NEW.department_id     is distinct from OLD.department_id
  or NEW.created_at        is distinct from OLD.created_at
  then
    raise exception
      'Only first_name, last_name and middle_name may be updated directly. '
      'role/cohort_id/class_rep_rank change via create_cohort_with_class_rep, '
      'promote_class_rep or demote_class_rep; faculty_rep status via '
      'bootstrap_faculty_rep; email and email_verified_at are written only by '
      'the auth sync trigger on an OAuth signup.'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_users_self_update() from public, anon, authenticated;


-- ============================================================================
-- 3. Grants
-- ============================================================================
-- REVOKE FROM PUBLIC FIRST — CREATE FUNCTION implicitly grants EXECUTE to
-- PUBLIC (0014 §3).
--
-- service_role ONLY, and not authenticated: this creates the role that every
-- other role's authority descends from. A faculty rep who could call it would
-- be able to mint peers, and a class rep or student calling it would break the
-- chain outright.
revoke execute on function bootstrap_faculty_rep(uuid, uuid) from public, anon, authenticated;
grant  execute on function bootstrap_faculty_rep(uuid, uuid) to service_role;
