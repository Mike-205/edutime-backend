-- ============================================================================
-- 0044: identity_linked audit event
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §8 names this as the audit event for the linking
-- flows (§5/§6, plan 4/5). Added on its own, in its own migration file and
-- transaction — Postgres refuses to use a new enum value in the same
-- transaction that added it, and the functions that write this value
-- (0045, 0046) are deliberately separate files applied after this one
-- commits.
--
-- Not a full rebuild of roster_audit_action: AUTH_FLOW_REFACTOR.md §8 also
-- describes dropping 'created'/'updated'/'removed' (dead once the old
-- roster's writers retire) and renaming roster_audit_log itself — both are
-- Plan 5's job, once the old roster path is actually gone. Adding one new
-- value here doesn't block that later rebuild.
-- ============================================================================

alter type roster_audit_action add value 'identity_linked';
