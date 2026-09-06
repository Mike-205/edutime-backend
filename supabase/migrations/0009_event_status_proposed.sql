-- ============================================================================
-- 0009: event_status gets a 'proposed' value
-- ============================================================================
-- A combined (cross-cohort) lecture sits in 'proposed' from the moment the
-- initiating rep creates it until every attached cohort's rep has
-- confirmed. Kept in its own migration because ALTER TYPE ... ADD VALUE
-- cannot be used in the same transaction as any statement that references
-- the new value (a Postgres restriction) — 0010 depends on 'proposed'
-- existing already, so this must land first, in its own file.
alter type event_status add value if not exists 'proposed';

-- notif_type gains two values for the combined-lecture workflow, kept in
-- this same isolated migration for the same transaction-boundary reason.
alter type notif_type add value if not exists 'cohort_confirmation_needed';
alter type notif_type add value if not exists 'combined_lecture_declined';