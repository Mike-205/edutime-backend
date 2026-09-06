-- ============================================================================
-- 0038: claim_method column on users
-- ============================================================================
-- Part 2 of 5 of the OAuth-only auth redesign (AUTH_FLOW_REFACTOR.md).
-- STRUCTURE ONLY, same discipline as 0037: no function reads or writes this
-- column yet. AUTH_FLOW_REFACTOR.md §2's rule is that claim_method is the
-- only column any access decision reads — today that decision lives on
-- student_roster.claim_method (0017); this is the column the redesign moves
-- it to, once claim_identity_personal (0040, this plan) and the later Flow 2
-- function (Plan 3) exist to write it. student_roster.claim_method is left
-- completely untouched here; it retires in Plan 5.
--
-- Reuses the existing claim_method enum (0017) for a NEW column — this is
-- safe in a single migration. The restriction on ALTER TYPE ... ADD VALUE
-- (cannot run inside the same transaction that uses the new value) is about
-- adding a value to an EXISTING type; it does not apply to using an
-- already-committed type for a new column. claim_method's two values
-- ('oauth', 'provisional') were both committed back in 0017, so there is
-- nothing that needs splitting across migrations here.
-- ============================================================================

alter table users
  add column claim_method claim_method;

comment on column users.claim_method is
  'The only column any access decision reads (AUTH_FLOW_REFACTOR.md §2). '
  'NULL until an identity is claimed. Written only by claim_identity_personal '
  '(Flow 1, 0040) and its Flow 2 counterpart (Plan 3) — never by client code, '
  'never by this migration.';

-- guard_users_self_update extended — see 0037 §5's note: an unlisted column
-- is a column this trigger says nothing about, so the new column joins the
-- list in the same migration that creates it, even before any writer
-- function for it exists.
--
-- CREATE OR REPLACE discards proconfig — 0019 recorded this after it
-- silently un-pinned handle_new_auth_user. `set search_path = public` is
-- restated, not decoration.
create or replace function guard_users_self_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return NEW;
  end if;

  if NEW.id                         is distinct from OLD.id
  or NEW.role                       is distinct from OLD.role
  or NEW.class_rep_rank             is distinct from OLD.class_rep_rank
  or NEW.cohort_id                  is distinct from OLD.cohort_id
  or NEW.reg_number                 is distinct from OLD.reg_number
  or NEW.email                      is distinct from OLD.email
  or NEW.email_verified_at          is distinct from OLD.email_verified_at
  or NEW.faculty_id                 is distinct from OLD.faculty_id
  or NEW.department_id              is distinct from OLD.department_id
  or NEW.created_at                 is distinct from OLD.created_at
  or NEW.programme_id                is distinct from OLD.programme_id
  or NEW.self_sponsored              is distinct from OLD.self_sponsored
  or NEW.student_number              is distinct from OLD.student_number
  or NEW.admission_year              is distinct from OLD.admission_year
  or NEW.school_email                is distinct from OLD.school_email
  or NEW.school_email_verified_at    is distinct from OLD.school_email_verified_at
  or NEW.personal_email              is distinct from OLD.personal_email
  or NEW.personal_email_verified_at  is distinct from OLD.personal_email_verified_at
  or NEW.claim_method                is distinct from OLD.claim_method
  then
    raise exception
      'Only first_name, last_name and middle_name may be updated directly. '
      'role/cohort_id/class_rep_rank change via create_cohort_with_class_rep, '
      'promote_class_rep or demote_class_rep; faculty_rep status via '
      'bootstrap_faculty_rep; email and email_verified_at are written only by '
      'the auth sync trigger on an OAuth signup; programme_id, '
      'self_sponsored, student_number, admission_year, school_email, '
      'school_email_verified_at, personal_email, personal_email_verified_at '
      'and claim_method are written only by the identity-claim and '
      'identity-link functions.'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function guard_users_self_update() from public, anon, authenticated;
