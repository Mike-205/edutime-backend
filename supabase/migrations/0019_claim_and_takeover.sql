-- ============================================================================
-- 0019: Claiming an identity — bind, take over, dispute
-- ============================================================================
-- Phase R part 3 of 3, and the point of the whole phase. 0017 declared who
-- exists; this decides how a person proves a row is theirs, and closes the hole
-- TECHNICAL_DISCOVERY §2 flags: authority was anchored in the real world, identity
-- was not.
--
-- The flow (TODO §0.5):
--
--   registration number + full name
--     -> roster match?  no  -> ONE generic message, rate-limited upstream
--                       yes -> set up credentials
--                                university email (OAuth) -> §2 binds, verified
--                                password                 -> §2 binds, provisional
--
-- Contents
--   §1  reg_number_from_email()  — the reverse derivation
--   §2  claim_roster_row()       — bind, and take over a provisional claim
--   §3  resolve_roster_dispute() — the faculty rep's manual override
--   §4  handle_new_auth_user()   — stop trusting client metadata
--   §5  mark_email_verified()    — dropped, not hardened
--
-- THE ONE RULE. On the OAuth branch, the address the provider returns must
-- parse back to the registration number the student typed. Without that check
-- the roster is decorative: anyone could type a classmate's number and then
-- authenticate with their own Google account. It is enforced in §2 and it is
-- the single most important condition in this file.
-- ============================================================================


-- ============================================================================
-- 1. reg_number_from_email
-- ============================================================================
-- The inverse of the address pattern: 'eb1.67277.23@student.chuka.ac.ke'
-- describes registration number 'EB1/67277/23'.
--
-- We never GENERATE or STORE an address from a registration number — §10 of
-- TECHNICAL_DISCOVERY explains why that would be actively harmful, since a
-- derived string setting email_verified_at fakes the one trust signal that
-- means anything. This goes the other way: it takes an address a provider
-- already proved and works out which roster row it describes. The derived
-- string is compared and discarded, never persisted.
--
-- Returns null for anything that is not a student address in the expected
-- shape — staff addresses (@chuka.ac.ke), personal addresses, and the
-- synthetic @auth.internal logins all fall through to null, which callers read
-- as "this account proves no identity".
create or replace function reg_number_from_email(p_email text)
returns text
language plpgsql
immutable
as $$
declare
  v_email text;
  v_local text;
  v_reg   text;
begin
  if p_email is null then
    return null;
  end if;

  v_email := lower(regexp_replace(p_email, '\s', '', 'g'));

  if v_email !~ '^[^@]+@student\.chuka\.ac\.ke$' then
    return null;
  end if;

  v_local := split_part(v_email, '@', 1);
  v_reg   := upper(replace(v_local, '.', '/'));

  -- Shape-check the result rather than trusting the address. An address like
  -- 'j.doe@student.chuka.ac.ke' is a perfectly valid mailbox that describes no
  -- registration number, and must not be allowed to half-parse.
  if v_reg !~ '^[A-Z]+[0-9]*/[0-9]+/[0-9]{2}$' then
    return null;
  end if;

  return v_reg;
end;
$$;

comment on function reg_number_from_email(text) is
  'Derives the registration number an @student.chuka.ac.ke address describes. '
  'Null for any other address shape. The result is compared, never stored.';

revoke execute on function reg_number_from_email(text) from public, anon;
grant  execute on function reg_number_from_email(text) to authenticated, service_role;


-- ============================================================================
-- 2. claim_roster_row
-- ============================================================================
-- Binds the calling account to a roster row.
--
-- On failure to match, every path raises the SAME message. Distinguishing
-- "no such registration number" from "that name does not match" would turn
-- this function into an oracle for probing the roster — and since the roster
-- is exactly the name+number pairs an attacker needs, that oracle would hand
-- over the material the write-mostly rule in 0017 §6 exists to withhold. The
-- cost is a worse error for a student with a typo, which is why the message
-- points at a human who can look it up for them.
--
-- TAKEOVER. The password branch cannot prove anything — there is no channel to
-- verify against, and SMS, rep-issued codes and a private roster field were all
-- considered and rejected (TODO §0.5). So a classmate CAN claim an unclaimed
-- row with a password. The answer is not prevention, it is that the claim is
-- worthless: when the real owner signs in with the university address that
-- proves the identity, the row rebinds to them and the squatter's account goes
-- inert. Damage is bounded because student accounts are read-only — the harm
-- was only ever denying someone their own account, and this undoes it.
create or replace function claim_roster_row(
  p_reg_number  text,
  p_first_name  text,
  p_last_name   text,
  p_acting_user uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user      users;
  v_row       student_roster;
  v_existing  student_roster;
  v_norm      text;
  v_derived   text;
  v_method    claim_method;
  v_old_role  user_role;
  v_old_user  uuid;
begin
  if p_acting_user is distinct from auth.uid() then
    raise exception 'p_acting_user must match the calling user';
  end if;

  select * into v_user from users where id = p_acting_user;

  if v_user.id is null then
    raise exception 'Acting user % not found', p_acting_user;
  end if;

  v_norm := normalize_reg_number(p_reg_number);

  -- Idempotent re-claim, and a guard against one account collecting identities.
  select * into v_existing from student_roster where claimed_by = p_acting_user;

  if v_existing.id is not null then
    if v_existing.reg_number = v_norm then
      return v_existing.id;
    end if;
    raise exception 'This account has already claimed a different identity';
  end if;

  -- Number AND name must both match. The name is not a second factor — a
  -- classmate knows it, and on the OAuth branch below it is never consulted at
  -- all. It is here because the student typed it, so a mismatch is a signal
  -- something is wrong, and because it makes a wrong-number typo fail closed.
  select * into v_row
  from student_roster
  where reg_number = v_norm
    and lower(first_name) = lower(trim(coalesce(p_first_name, '')))
    and lower(last_name)  = lower(trim(coalesce(p_last_name, '')));

  if v_row.id is null then
    raise exception
      'We could not match those details. Check your registration number and full name with your class rep.';
  end if;

  -- How much is this account's word worth?
  if v_user.email is not null and v_user.email_verified_at is not null then
    v_derived := reg_number_from_email(v_user.email);

    -- *** THE RULE ***
    if v_derived is null or v_derived <> v_norm then
      raise exception
        'This university account does not belong to registration number %', v_norm;
    end if;

    v_method := 'oauth';
  else
    v_method := 'provisional';
  end if;

  if v_row.claimed_by is not null then
    -- An OAuth claim is provider-proven; nothing outranks it.
    if v_row.claim_method = 'oauth' then
      raise exception 'That identity has already been claimed';
    end if;

    -- Provisional cannot displace provisional — otherwise the row would just
    -- ping-pong between whoever ran the flow most recently.
    if v_method <> 'oauth' then
      raise exception 'That identity has already been claimed';
    end if;

    select role into v_old_role from users where id = v_row.claimed_by;

    -- The one case that must never be automatic. Evicting an account that
    -- holds scheduling authority would strip a cohort's rep mid-semester on a
    -- signup event, with no human in the loop. Escalate instead.
    if v_old_role = 'class_rep' then
      raise exception
        'That identity is held by an account with scheduling authority. A faculty rep must resolve this.';
    end if;

    v_old_user := v_row.claimed_by;

    -- Inert, not deleted: the account keeps its notifications and its history,
    -- and after 0014 an account with no cohort can see essentially nothing.
    -- Deleting would also hit 2.3's ON DELETE RESTRICT chain.
    update users
    set reg_number = null,
        cohort_id  = null
    where id = v_old_user;

    insert into notifications (user_id, event_id, title, message, type)
    values (
      v_old_user, null,
      'Your account has been unlinked',
      'The university account for this registration number signed in, so the '
      || 'identity has moved to it. If you believe this is wrong, contact your faculty rep.',
      'account_taken_over'
    );

    insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
    values (
      v_row.id, v_norm, 'takeover', p_acting_user, v_old_user,
      jsonb_build_object('from_method', v_row.claim_method, 'to_method', v_method)
    );
  end if;

  update student_roster
  set claimed_by   = p_acting_user,
      claimed_at   = now(),
      claim_method = v_method,
      updated_at   = now()
  where id = v_row.id;

  -- The roster is authoritative for the official name and the cohort. Both
  -- overwrite whatever the client passed at signup.
  update users
  set reg_number  = v_norm,
      cohort_id   = v_row.cohort_id,
      first_name  = v_row.first_name,
      last_name   = v_row.last_name,
      middle_name = v_row.middle_name
  where id = p_acting_user;

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    v_row.id, v_norm, 'claimed', p_acting_user, p_acting_user,
    jsonb_build_object('method', v_method, 'cohort_id', v_row.cohort_id)
  );

  return v_row.id;
end;
$$;

revoke execute on function claim_roster_row(text, text, text, uuid) from public, anon;
grant  execute on function claim_roster_row(text, text, text, uuid)
  to authenticated, service_role;


-- ============================================================================
-- 3. resolve_roster_dispute
-- ============================================================================
-- The manual override, for when someone finds their identity already held.
--
-- FACULTY REP, not class rep. The class rep is inside the cohort and may be the
-- problem; the faculty rep is the trust anchor TECHNICAL_DISCOVERY §2 already
-- relies on for exactly this kind of real-world adjudication.
--
-- The verification is physical and out-of-band — the student turns up with an
-- ID card — so there is nothing to build for the reporting side. That also
-- means this function has no way to know whether the rep actually checked,
-- which is precisely why the audit row is not optional. Watch the reverse
-- abuse: someone claiming a legitimately held account is theirs.
--
-- Unbinds; it does not delete. The freed row can then be claimed normally.
create or replace function resolve_roster_dispute(
  p_roster_id          uuid,
  p_acting_faculty_rep uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role      user_role;
  v_faculty   uuid;
  v_row       student_roster;
  v_row_fac   uuid;
  v_old_user  uuid;
begin
  if p_acting_faculty_rep is distinct from auth.uid() then
    raise exception 'p_acting_faculty_rep must match the calling user';
  end if;

  select role, faculty_id into v_role, v_faculty
  from users where id = p_acting_faculty_rep;

  if v_role is distinct from 'faculty_rep' then
    raise exception 'Only a faculty_rep may resolve an identity dispute';
  end if;

  if v_faculty is null then
    raise exception 'This faculty_rep has no faculty_id set and cannot resolve disputes';
  end if;

  select * into v_row from student_roster where id = p_roster_id;

  if v_row.id is null then
    raise exception 'Roster row % does not exist', p_roster_id;
  end if;

  if v_row.claimed_by is null then
    raise exception 'Roster row % is not claimed — there is nothing to resolve', p_roster_id;
  end if;

  select d.faculty_id into v_row_fac
  from cohorts c
  join programmes p  on p.id = c.programme_id
  join departments d on d.id = p.department_id
  where c.id = v_row.cohort_id;

  if v_row_fac is distinct from v_faculty then
    raise exception 'Roster row % belongs to another faculty', p_roster_id;
  end if;

  v_old_user := v_row.claimed_by;

  update users
  set reg_number = null,
      cohort_id  = null
  where id = v_old_user;

  update student_roster
  set claimed_by   = null,
      claimed_at   = null,
      claim_method = null,
      updated_at   = now()
  where id = p_roster_id;

  insert into notifications (user_id, event_id, title, message, type)
  values (
    v_old_user, null,
    'Your account has been unlinked',
    'A faculty rep has unlinked this account from its registration number. '
    || 'Contact them if you believe this is a mistake.',
    'identity_unbound'
  );

  insert into roster_audit_log (roster_id, reg_number, action, actor_id, target_user, snapshot)
  values (
    p_roster_id, v_row.reg_number, 'dispute_resolved', p_acting_faculty_rep, v_old_user,
    jsonb_build_object('previous_method', v_row.claim_method)
  );
end;
$$;

revoke execute on function resolve_roster_dispute(uuid, uuid) from public, anon;
grant  execute on function resolve_roster_dispute(uuid, uuid) to authenticated, service_role;


-- ============================================================================
-- 4. handle_new_auth_user stops trusting client metadata
-- ============================================================================
-- This trigger is the actual hole Phase R exists to close. It copied
--
--     new.raw_user_meta_data ->> 'reg_number'
--
-- straight from whatever the client sent, into the column the entire trust
-- model rests on. Leaving it in place while adding the roster would just be a
-- second, unguarded door into the same field.
--
-- After this, a freshly created account has a name and possibly an email, and
-- NOTHING ELSE — no registration number, no cohort. Post-0014 that account can
-- see almost nothing, which is the correct resting state for someone who has
-- not yet proved who they are. claim_roster_row (§2) is the only way out of it.
--
-- The name still comes from metadata, and that is fine: a name carries no
-- authority, it is only a display value until §2 overwrites it from the roster.
-- `set search_path` is NOT decoration here. 0008 §1 pinned this function with
-- `alter function ... set search_path = public`, and CREATE OR REPLACE discards
-- proconfig — so replacing the body without restating it silently un-pins a
-- SECURITY DEFINER function and reopens the exact escalation vector 0008 closed.
-- 00_access_control_test.sql catches this; do not remove the line to "match
-- 0002", which predates the pinning.
create or replace function handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (
    id,
    email,
    email_verified_at,
    first_name,
    last_name,
    middle_name
    -- reg_number is deliberately absent. See the note above.
  )
  values (
    new.id,
    -- Only store the REAL email if this was an OAuth signup; reg-number signups
    -- pass the synthetic address in new.email, which must NOT leak into
    -- public.users.email.
    case
      when new.raw_app_meta_data ->> 'provider' in ('google', 'apple')
        then new.email
      else null
    end,
    case
      when new.raw_app_meta_data ->> 'provider' in ('google', 'apple')
        then now()
      else null
    end,
    coalesce(new.raw_user_meta_data ->> 'first_name', ''),
    coalesce(new.raw_user_meta_data ->> 'last_name', ''),
    new.raw_user_meta_data ->> 'middle_name'
  );
  return new;
end;
$$;

revoke execute on function handle_new_auth_user()
  from public, anon, authenticated, service_role;


-- ============================================================================
-- 5. mark_email_verified is dropped, not hardened
-- ============================================================================
-- TODO §1.5 recorded this as "add a domain check". After the roster there is
-- nothing left to check.
--
-- The function accepted any string with no proof of ownership, so a student
-- could self-award the verified badge with a personal address. It was contained
-- only because verification granted no permissions. Hardening it would mean
-- validating a claim the client makes about itself — but email_verified_at is
-- now written in exactly one place, by 0002's trigger, from an address the
-- OAuth provider proved. There is no client assertion left in the flow.
--
-- Keeping a hardened version would preserve a second, weaker way to set the
-- same field, which is the shape of bug 0014 spent 1,400 lines removing.
drop function if exists mark_email_verified(uuid, text);
