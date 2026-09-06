-- ============================================================================
-- 0020: enum values for attendance confirmation
-- ============================================================================
-- Phase 1 part 1 of 3. Alone, for the reason 0009, 0011 and 0018 are alone:
-- `ALTER TYPE ... ADD VALUE` cannot share a transaction with anything that
-- references the new value, and 0022 references all four of these.
--
-- Do not merge this into its neighbours.
-- ============================================================================

-- audit_action has only ever had the four structural verbs. Confirming that a
-- lecturer is actually coming is a distinct act by a distinct person at a
-- distinct time — folding it into 'updated' would make the audit log unable to
-- answer "who made the confirmation call, and when", which is the entire point
-- of tracking attendance separately (TECHNICAL_DISCOVERY §5).
alter type audit_action add value if not exists 'confirmed';
alter type audit_action add value if not exists 'unconfirmed';

-- notif_type already has 'confirmation_needed' — the nudge TO a rep, asking
-- them to make the call. These are the opposite direction: the outcome, fanned
-- out to the cohort.
alter type notif_type add value if not exists 'attendance_confirmed';
alter type notif_type add value if not exists 'attendance_unconfirmed';
