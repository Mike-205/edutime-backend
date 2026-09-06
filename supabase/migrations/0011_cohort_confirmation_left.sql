-- ============================================================================
-- 0011: cohort_confirmation_status gains a 'left' value
-- ============================================================================
-- Distinct from 'declined': declining happens BEFORE an event is fully
-- scheduled and cancels the whole event for everyone. 'left' happens AFTER
-- an event is already 'scheduled' — a non-initiating cohort's rep opts
-- their own cohort out without affecting anyone else's already-confirmed
-- lecture. Isolated in its own migration for the usual enum ADD VALUE /
-- same-transaction restriction — 0012 depends on this value existing.
alter type cohort_confirmation_status add value if not exists 'left';