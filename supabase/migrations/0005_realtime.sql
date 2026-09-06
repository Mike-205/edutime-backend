-- ============================================================================
-- 0005: Realtime — cohort-scoped broadcast, not per-row subscriptions
-- ============================================================================
-- WHY BROADCAST INSTEAD OF postgres_changes: if every student subscribed
-- directly to postgres_changes on `events`, RLS gets re-evaluated per
-- connected client per row change — cost scales with (students x changes).
-- Broadcast instead fans out ONE lightweight pub/sub message per cohort
-- channel; RLS is only evaluated once, when the client does its own
-- follow-up SELECT. Number of students watching a cohort barely affects
-- cost this way.
--
-- WHY id + action ONLY, not the full row: this app's core job is venue-
-- conflict prevention, so correctness beats round-trip savings. A full-row
-- payload could go stale (client missed an intermediate update, two writes
-- raced) and get patched into local state directly, risking a student
-- seeing an already-superseded time/venue. Forcing a refetch means every
-- client re-validates against current DB state AND current RLS.
create or replace function notify_cohort_event_change()
returns trigger
language plpgsql
security definer
as $$
declare
  affected_cohort_id uuid;
  change_action text;
begin
  if TG_OP = 'DELETE' then
    affected_cohort_id := OLD.cohort_id;
    change_action := 'deleted';
  else
    affected_cohort_id := NEW.cohort_id;
    change_action := case
      when TG_OP = 'INSERT' then 'created'
      when TG_OP = 'UPDATE' and NEW.status = 'canceled'
           and OLD.status != 'canceled' then 'canceled'
      when TG_OP = 'UPDATE' and NEW.status = 'rescheduled'
           and OLD.status != 'rescheduled' then 'rescheduled'
      when TG_OP = 'UPDATE' and NEW.attendance_status = 'confirmed'
           and OLD.attendance_status = 'pending' then 'confirmation_needed'
      else 'updated'
    end;
  end if;

  perform realtime.broadcast_changes(
    'cohort:' || affected_cohort_id || ':events',  -- one channel per cohort,
                                                     -- not per user/row
    change_action,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    jsonb_build_object('id', NEW.id),
    jsonb_build_object('id', OLD.id)
  );

  return coalesce(NEW, OLD);
end;
$$;

create trigger events_broadcast_trigger
after insert or update or delete on events
for each row
execute function notify_cohort_event_change();
