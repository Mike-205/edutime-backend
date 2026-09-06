-- ============================================================================
-- 0043: users — column-level SELECT hardening
-- ============================================================================
-- 0006's users_read_all policy is `auth.uid() is not null` — any signed-in
-- account, any row — and 0014 §4 backs it with `grant select on ... users`
-- for the WHOLE table. RLS filters rows, not columns, so the combination
-- means every student can read every OTHER student's school_email,
-- personal_email, reg_number, student_number and the rest of the identity
-- columns Plans 1-3 (AUTH_FLOW_REFACTOR.md) built. 0017 §5 saw this exact
-- shape coming for recovery_email and split it onto its own self-only table
-- rather than widen users further — this migration closes the same gap on
-- users itself, the way that comment said a column-level grant eventually
-- would.
--
-- Fix: replace the table-wide grant with a column-level one covering only
-- what a directory listing needs (name, role, cohort/org placement) — a
-- table-level SELECT grant dominates column grants, so it has to be
-- revoked, not left in place alongside a narrower one. Every access
-- decision inside this schema that reads a `users` row cross-account
-- already goes through current_app_user() (0006, SECURITY DEFINER, EXECUTE
-- already granted to authenticated by 0008 §3) or an inline RLS-policy
-- subquery that only ever touches id/role/cohort_id/faculty_id — verified
-- by inspection of every `create policy` in 0006/0010/0016/0017/0022/0033
-- before writing this. Self-service full-profile reads (a client needing
-- their OWN reg_number, school_email, etc.) keep working unchanged via that
-- same current_app_user() RPC, which selects by auth.uid() and is unaffected
-- by table grants since it runs as the function owner.
--
-- Side effect, worth knowing rather than tripping over later: any column
-- users gains from here on starts UNGRANTED to authenticated by default —
-- opt-in, not opt-out. And a client `select *` against users now fails
-- outright with 42501 instead of silently dropping columns; only an
-- explicit column list against the granted set succeeds.
-- ============================================================================

revoke select on users from authenticated;

grant select (
  id, first_name, last_name, middle_name,
  role, cohort_id, class_rep_rank,
  department_id, faculty_id,
  created_at
) on users to authenticated;
