-- ============================================================================
-- 0053: Drop student_roster and the functions built only for it
-- ============================================================================
-- AUTH_FLOW_REFACTOR.md §10: this retires student_roster, the password/
-- auth.internal signup path, and claim_roster_row's roster-matching logic
-- outright. Seven of these eight functions (everything except
-- resolve_roster_dispute) are simply obsolete: what they did has a
-- new-system replacement already shipped in Plans 1-4 (claim_identity_personal,
-- commit_school_identity, link_school_email_identity), and nothing calls
-- their old shape any more.
--
-- resolve_roster_dispute is different -- §10 is explicit that it is "not
-- fully retired," only its body. It is dropped HERE because that body
-- operates on student_roster rows, which no longer exist -- but its JOB
-- (a faculty rep resolving §5's disputed-link escalation) is not going
-- away, and this plan's own Task 6 (resolve_identity_dispute) is what
-- serves it now, built from scratch against users columns instead of a
-- roster row. Do not read this drop as "the spec's correction was
-- ignored" -- Task 6 is that correction, landing before this task.
--
-- Plain DROP TABLE, no CASCADE: identity_audit_log's former roster_id
-- column (the only foreign key into this table) was already dropped in
-- Task 3, so this drop has nothing left to fail loudly about. If it does
-- fail, something in this plan's ordering assumption was wrong -- do not
-- add CASCADE to make the error go away; find and fix the real dependency.
drop function roster_assert_may_write(uuid, text, uuid);
drop function roster_add_student(text, text, text, text, uuid, uuid);
drop function roster_bulk_import(jsonb, uuid, uuid);
drop function roster_correct_student(uuid, text, text, text, text, uuid);
drop function roster_remove_student(uuid, uuid);
drop function claim_roster_row(text, text, text, uuid);
drop function resolve_roster_dispute(uuid, uuid);
drop function unclaimed_synthetic_signups();

drop table student_roster;


-- ============================================================================
-- Enum rebuild — deferred here from Task 3 (controller ruling): narrowing
-- roster_audit_action was unsafe until the last writers of 'created'/
-- 'updated'/'removed' (the four functions just dropped above --
-- roster_add_student, roster_bulk_import, roster_correct_student,
-- roster_remove_student) were gone. Task 3 (0049) rebuilt the audit table
-- itself but deliberately left the enum untouched for exactly this reason --
-- see 0049's header comment. This is the first migration where those three
-- values have no live writer left, so it is the first point this rebuild is
-- safe. CREATE TYPE ... AS ENUM + USING cast, not ALTER TYPE ... ADD VALUE,
-- matching the plan's own established convention from 0044 -- a new value
-- cannot be used in the same transaction it is added in, but a wholesale
-- replacement type has no such restriction.
create type identity_audit_action as enum (
  'claimed', 'takeover', 'unbound', 'dispute_resolved', 'identity_linked', 'reassigned'
);

alter table identity_audit_log
  alter column action type identity_audit_action
  using action::text::identity_audit_action;

drop type roster_audit_action;
