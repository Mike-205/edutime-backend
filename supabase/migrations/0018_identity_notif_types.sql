-- ============================================================================
-- 0018: notif_type values for the identity flows
-- ============================================================================
-- Phase R part 2 of 3. This migration exists ONLY to widen an enum, and it has
-- to be alone for the same reason 0009 and 0011 are alone: Postgres will not
-- let `ALTER TYPE ... ADD VALUE` share a transaction with anything that
-- references the new value. 0019 references both of these, so it cannot carry
-- them itself.
--
-- Do not merge this into its neighbours. It looks trivially small and it is
-- load-bearing.
--
-- Note the contrast with 0017, which creates `claim_method` and uses it in the
-- same file: creating a brand-new enum type is unrestricted. The restriction
-- is only on adding a value to a type that already exists.
-- ============================================================================

-- Sent to an account that just lost its roster row because the real owner
-- signed in with the university email that proves the identity. The account
-- itself survives — it keeps its notifications and loses its cohort — so the
-- person holding it needs to be told why the app went empty.
alter type notif_type add value if not exists 'account_taken_over';

-- Sent when a faculty rep severs a claimed identity from an account during
-- dispute resolution. Distinct from a takeover: a human adjudicated this one,
-- and the account may have been in the wrong.
alter type notif_type add value if not exists 'identity_unbound';
