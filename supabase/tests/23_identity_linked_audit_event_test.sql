-- ============================================================================
-- 23: identity_linked audit event (0044)
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §8 names identity_linked as the audit event for the
-- linking flows this plan (4/5) adds. Added as its own migration, separate
-- from anything that writes a row with it — ALTER TYPE ... ADD VALUE cannot
-- be used in the same transaction it's added in, and each migration file is
-- its own transaction.
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(1);

-- roster_audit_action was renamed to identity_audit_action and narrowed by
-- 0053 (Plan 5, Task 7) once its old-system-only values ('created',
-- 'updated', 'removed') had no live writer left. identity_linked survives
-- that rebuild, so this assertion still holds against the new type name.
select ok(
  'identity_linked' = any(enum_range(null::identity_audit_action)::text[]),
  'identity_audit_action retains identity_linked'
);

select * from finish();
rollback;
