-- ============================================================================
-- 0048: Retire the recovery-email subsystem
-- ============================================================================
-- user_recovery_email (0017/0031), set_recovery_email, verify_recovery_email
-- and request_password_recovery existed to serve the password/auth.internal
-- signup path — request_password_recovery's own comment calls it "the
-- reg-number/password branch's recovery path" explicitly. That path retires
-- in this plan (Task 7); this subsystem has no caller left once it does.
-- Plan 4's link_personal_email_identity (0046) is the modern replacement: a
-- linked personal email as the account's lifeline past graduation, with no
-- separate setup-code/verification dance needed.
drop function request_password_recovery(text);
drop function verify_recovery_email(text, uuid);
drop function set_recovery_email(text, uuid);
drop table user_recovery_email;
