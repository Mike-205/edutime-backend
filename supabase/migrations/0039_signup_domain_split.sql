-- ============================================================================
-- 0039: handle_new_auth_user learns the school/personal email split
-- ============================================================================
-- Part 3 of 5. ADDITIVE ONLY: this is not a rewrite of the OAuth branch, it
-- is an extension. handle_new_auth_user cannot know, at signup time, whether
-- a new google/apple account will go on to run the old roster claim
-- (claim_roster_row, 0019 — still live, still unretired until Plan 5) or the
-- new Flow 1 identity claim (0040, this plan) or a future Flow 2 claim
-- (Plan 3). All three are, from this trigger's point of view,
-- indistinguishable: "a new OAuth signup". So the old write (users.email /
-- users.email_verified_at, unconditional on provider) is left EXACTLY as it
-- was — claim_roster_row (0019:171) still reads it and must keep working —
-- and the new write (school_email or personal_email, chosen by address
-- domain) is added alongside it, never in its place.
--
-- The domain test uses is_school_email (below), NOT reg_number_from_email
-- (0019) — reg_number_from_email returns null for two different reasons: an
-- address that isn't @student.chuka.ac.ke at all, and an address that IS
-- @student.chuka.ac.ke but whose local part doesn't shape-check to a
-- registration number (e.g. 'j.doe@student.chuka.ac.ke', a perfectly valid
-- student mailbox). Reusing reg_number_from_email here would file that
-- second case as personal_email, which is wrong — a genuine institutional
-- address must always be filed as school_email regardless of whether its
-- local part happens to look like a registration number.
--
-- `set search_path` is restated, not decoration — see 0019 §4's own note on
-- this exact function.
-- ============================================================================

-- ============================================================================
-- 0. is_school_email
-- ============================================================================
-- The domain-only half of reg_number_from_email's (0019) check. Uses the
-- exact same normalization (lower + strip whitespace) and the exact same
-- domain regex, so the two functions can never disagree on case or
-- whitespace handling — only on what they do with a non-reg-number-shaped
-- local part, which is the whole point of having both.
create or replace function is_school_email(p_email text)
returns boolean
language sql
immutable
as $$
  select p_email is not null
     and lower(regexp_replace(p_email, '\s', '', 'g')) ~ '^[^@]+@student\.chuka\.ac\.ke$';
$$;

comment on function is_school_email(text) is
  'The domain-only half of reg_number_from_email''s check (0019) — true for '
  'any @student.chuka.ac.ke address regardless of whether the local part is '
  'reg-number-shaped. handle_new_auth_user uses this (not '
  'reg_number_from_email) to decide the email tier, because a genuine '
  'institutional address with a non-reg-number-shaped local part must still '
  'be filed as school_email, not personal_email.';

revoke execute on function is_school_email(text) from public, anon;
grant  execute on function is_school_email(text) to authenticated, service_role;


create or replace function handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_oauth  boolean;
  v_is_school boolean;
begin
  v_is_oauth  := (new.raw_app_meta_data ->> 'provider') in ('google', 'apple');
  v_is_school := v_is_oauth and is_school_email(new.email);

  insert into public.users (
    id,
    email,
    email_verified_at,
    first_name,
    last_name,
    middle_name,
    school_email,
    school_email_verified_at,
    personal_email,
    personal_email_verified_at
    -- reg_number is deliberately absent. See 0019 §4's note.
  )
  values (
    new.id,
    -- Unchanged from 0019: only store the REAL email if this was an OAuth
    -- signup; reg-number signups pass the synthetic address in new.email,
    -- which must NOT leak into public.users.email.
    case when v_is_oauth then new.email else null end,
    case when v_is_oauth then now() else null end,
    coalesce(new.raw_user_meta_data ->> 'first_name', ''),
    coalesce(new.raw_user_meta_data ->> 'last_name', ''),
    new.raw_user_meta_data ->> 'middle_name',
    case when v_is_school then new.email else null end,
    case when v_is_school then now() else null end,
    case when v_is_oauth and not v_is_school then new.email else null end,
    case when v_is_oauth and not v_is_school then now() else null end
  );
  return new;
end;
$$;

revoke execute on function handle_new_auth_user()
  from public, anon, authenticated, service_role;
