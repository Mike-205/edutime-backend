-- ============================================================================
-- 0035: user_can_see_event's stale comment
-- ============================================================================
-- Same shape as 0032 §2's guard_users_self_update fix: a comment baked into
-- an already-applied function body, so it needs CREATE OR REPLACE in a new
-- migration rather than an edit to 0014's source — unlike a `--` source
-- comment with no applied history (0032 §0, correcting 0002), this one is
-- part of the function body pg_get_functiondef() actually returns.
--
-- 0014 wrote "NULL cohort_id (faculty reps, students not yet admitted to a
-- cohort)". That was true when written — the seed modelled faculty reps as
-- Deans with no cohort at all. It stopped being true on 2026-08-24: 0032's
-- domain-model correction made a faculty rep an ordinary student with a real
-- cohort_id, same as anyone else. The function's BEHAVIOUR was never wrong —
-- it fails closed on a NULL cohort_id regardless of whose account it is —
-- but the comment now describes a case that no longer applies to faculty
-- reps, and a reader taking it at face value would come away thinking
-- faculty reps structurally can't see events, which isn't true.
--
-- No functionality changes here — this is a comment-only CREATE OR REPLACE.
-- CREATE OR REPLACE discards proconfig, so `set search_path = public` and
-- `security definer` have to be restated (the trap 0019 recorded after it
-- silently un-pinned handle_new_auth_user); it preserves the existing ACL,
-- so 0014's revoke/grant lines for this function are untouched.
-- ============================================================================

create or replace function user_can_see_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- A user sees an event iff their own cohort is attached to it. Attachments
  -- that later went 'declined' or 'left' still count for VISIBILITY: a cohort
  -- that walked away from a lecture should still be able to see the row its
  -- own audit trail refers to. Clients filter on
  -- event_cohorts.confirmation_status to decide what belongs on the calendar.
  select exists (
    select 1
    from event_cohorts ec
    where ec.event_id = p_event_id
      -- NULL cohort_id (an account that has not yet claimed a roster row —
      -- see 0017/0019) makes this comparison NULL, so the exists() is false.
      -- Fails closed. NOT faculty reps: after 0032's domain-model correction
      -- a faculty rep is an ordinary student with a real cohort_id, so they
      -- reach this check the same way any other account does.
      and ec.cohort_id = (select u.cohort_id from users u where u.id = auth.uid())
  );
$$;
