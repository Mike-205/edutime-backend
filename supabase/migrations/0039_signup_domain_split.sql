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
-- The domain test reuses reg_number_from_email (0019) rather than inlining a
-- second copy of the '^[^@]+@student\.chuka\.ac\.ke$' regex — 0019's own
-- header warns against a derived/duplicated check drifting from the real
-- one. A non-null result already means "this is a school address of the
-- expected shape"; nothing else about that function's behavior is used
-- here.
--
-- `set search_path` is restated, not decoration — see 0019 §4's own note on
-- this exact function.
-- ============================================================================

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
  v_is_school := v_is_oauth and reg_number_from_email(new.email) is not null;

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
