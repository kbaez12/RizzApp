"""Real PostgreSQL regression tests. Local-only disposable database.
Run with PG_BIN pointing to PostgreSQL's bin directory and PGPORT pointing
at an isolated local cluster. Creates its own uniquely named test database.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import uuid

PG = Path(os.environ['PG_BIN']) / 'psql.exe'
PORT = os.environ['PGPORT']
DB = 'greenshot_ownership_test_' + uuid.uuid4().hex
ROOT = Path(__file__).resolve().parents[2]
A = '123e4567-e89b-42d3-a456-426614174000'
B = '123e4567-e89b-42d3-a456-426614174001'
C = '123e4567-e89b-42d3-a456-426614174002'

def sql(statement, database=DB):
    result = subprocess.run([str(PG), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1',
        '-h', '127.0.0.1', '-p', PORT, '-U', 'postgres', '-d', database,
        '-c', statement], capture_output=True, text=True)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()

def quote(value):
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, list):
        return 'array[' + ','.join(map(quote, value)) + ']::text[]'
    return "'" + str(value).replace("'", "''") + "'"

def event(kind='INITIAL_PURCHASE', user=A, transaction='apple-1',
          at='2026-10-18T01:00:00Z', aliases=None, sources=None, id=None,
          active=True, period='2026-10-01T00:00:00Z', product='monthly',
          expires='2099-11-01T00:00:00Z'):
    args = [id or str(uuid.uuid4()), kind, at, transaction,
            user or '', user, aliases if aliases is not None else [user],
            'plus', product, 'SANDBOX', 'APP_STORE', active,
            period, expires if active else None,
            kind == 'INITIAL_PURCHASE', sources or []]
    return json.loads(sql('select public.apply_revenuecat_event(' +
        ','.join(map(quote, args)) + ')'))

def usage(user=A):
    return json.loads(sql(f'select public.get_user_usage({quote(user)})'))

def reserve(user=A, action='generation'):
    return json.loads(sql('select public.reserve_user_usage(' +
        ','.join(map(quote, [user, str(uuid.uuid4()), action])) + ')'))

def transfer(user=B, sources=None, **kwargs):
    return event('TRANSFER', user=user, transaction='',
                 sources=sources or [A], at=kwargs.pop('at', '2026-10-18T02:00:00Z'), **kwargs)

class OwnershipTests(unittest.TestCase):
    def setUp(self):
        sql('truncate public.billing_accounts, public.revenuecat_webhook_events cascade')

    def test_new_purchase(self):
        self.assertEqual(event()['outcome'], 'applied')
        self.assertEqual(usage()['remaining'], 200)

    def test_webhook_before_sync(self):
        event()
        self.assertEqual(event('SERVER_SYNC', transaction='')['outcome'], 'applied')
        self.assertTrue(usage()['subscribed'])

    def test_sync_before_webhook(self):
        self.assertEqual(event('SERVER_SYNC', transaction='')['outcome'], 'pending_verification')
        self.assertEqual(sql('select count(*) from public.billing_accounts'), '0')
        event()
        self.assertEqual(event('SERVER_SYNC', transaction='')['outcome'], 'applied')

    def test_same_identity_restore(self):
        event(); reserve()
        for _ in range(3):
            event('SERVER_SYNC', transaction='')
        self.assertEqual(usage()['remaining'], 199)

    def test_different_identity_restore(self):
        event(); reserve()
        self.assertEqual(event('SERVER_SYNC', user=B, transaction='')['outcome'], 'pending_verification')
        self.assertFalse(usage(B)['subscribed'])
        transfer()
        self.assertEqual(usage(B)['remaining'], 199)
        self.assertEqual(sql('select count(*) from public.billing_accounts'), '1')

    def test_75_consumed_and_refinements_preserved(self):
        event()
        sql('update public.user_usage set analyses_used=75, refinements_remaining=1')
        transfer()
        self.assertEqual(usage(B)['remaining'], 125)
        self.assertEqual(usage(B)['refinements_remaining'], 1)

    def test_simultaneous_syncs_cannot_create_allowance(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: event('SERVER_SYNC', user=B, transaction=''), range(6)))
        self.assertTrue(all(r['outcome'] == 'pending_verification' for r in results))
        self.assertEqual(sql('select count(*) from public.billing_accounts'), '0')

    def test_concurrent_duplicate_webhook(self):
        id = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: event(id=id), range(4)))
        self.assertEqual(sum(r['outcome'] == 'applied' for r in results), 1)
        self.assertEqual(sum(r['outcome'] == 'duplicate' for r in results), 3)

    def test_late_transfer_cannot_reclaim_owner(self):
        event(); transfer()
        transfer(user=C, sources=[B], at='2026-10-18T04:00:00Z')
        self.assertEqual(transfer(at='2026-10-18T03:00:00Z')['outcome'], 'stale')
        self.assertTrue(usage(C)['subscribed'])
        self.assertFalse(usage(B)['subscribed'])

    def test_new_owner_has_different_purchase(self):
        event(); reserve()
        event(user=B, transaction='apple-2'); reserve(B); reserve(B)
        transfer()
        self.assertEqual(usage(B)['remaining'], 199)
        self.assertEqual(sql("select analyses_used from public.user_usage u join public.billing_accounts b on b.id=u.billing_account_id where original_transaction_id='apple-2'"), '2')
        self.assertEqual(sql('select count(*) from public.billing_accounts'), '2')

    def test_conflicting_source_aliases_fail_closed(self):
        event(aliases=[A, 'shared'])
        event(user=B, transaction='apple-2', aliases=[B, 'shared'])
        self.assertEqual(transfer(user=C, sources=['shared'])['outcome'], 'pending_verification')
        self.assertFalse(usage()['subscribed'])
        self.assertFalse(usage(B)['subscribed'])
        self.assertFalse(usage(C)['subscribed'])

    def test_missing_stable_transaction(self):
        self.assertEqual(event(transaction='')['outcome'], 'pending_verification')
        self.assertEqual(event(transaction='pending:'+A)['outcome'], 'pending_verification')
        self.assertEqual(sql('select count(*) from public.billing_accounts'), '0')

    def test_previous_owner_revoked(self):
        event(); transfer()
        self.assertEqual(reserve()['outcome'], 'subscription_required')
        self.assertEqual(event('SERVER_SYNC', transaction='')['outcome'], 'pending_verification')
        self.assertEqual(reserve(B)['outcome'], 'reserved')

    def test_pending_cannot_reserve(self):
        event('SERVER_SYNC', transaction='')
        self.assertEqual(reserve()['outcome'], 'subscription_required')
        self.assertEqual(sql('select count(*) from public.user_usage_requests'), '0')

    def test_transfer_before_purchase_retries(self):
        id = str(uuid.uuid4())
        self.assertEqual(transfer(id=id)['outcome'], 'pending_verification')
        event()
        self.assertFalse(usage()['subscribed'])
        self.assertEqual(transfer(id=id)['outcome'], 'applied')
        self.assertTrue(usage(B)['subscribed'])

    def test_late_lifecycle_cannot_revoke_destination(self):
        event(); transfer()
        self.assertEqual(event('EXPIRATION', active=False, at='2026-10-18T05:00:00Z')['outcome'], 'stale')
        self.assertTrue(usage(B)['subscribed'])

    def test_sync_does_not_hide_late_transfer(self):
        event()
        event('SERVER_SYNC', transaction='', at='2026-10-18T06:00:00Z')
        transfer()
        self.assertTrue(usage(B)['subscribed'])

    def test_competing_transfers_converge_by_event_time(self):
        event()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(transfer, user=B, at='2026-10-18T02:00:00Z'),
                       pool.submit(transfer, user=C, at='2026-10-18T03:00:00Z')]
            for future in futures:
                future.result()
        self.assertTrue(usage(C)['subscribed'])
        self.assertFalse(usage(B)['subscribed'])

    def test_equal_timestamp_transfers_fail_closed(self):
        event(); transfer()
        self.assertEqual(transfer(user=C)['outcome'], 'pending_verification')
        self.assertFalse(usage(B)['subscribed'])
        self.assertFalse(usage(C)['subscribed'])

    def test_transfer_back_preserves_original_allowance(self):
        event(); reserve(); transfer()
        transfer(user=A, sources=[B], at='2026-10-18T04:00:00Z')
        self.assertEqual(usage()['remaining'], 199)
        self.assertFalse(usage(B)['subscribed'])

    def test_alias_event_cannot_grant_another_identity(self):
        event()
        self.assertEqual(event('SUBSCRIBER_ALIAS', user=B, transaction='', aliases=[A, B])['outcome'], 'pending_verification')
        self.assertEqual(reserve(B)['outcome'], 'subscription_required')

class MonthlyAllowanceTests(unittest.TestCase):
    def setUp(self):
        sql('truncate public.billing_accounts, public.revenuecat_webhook_events cascade')

    def window(self, anchor, at, timezone='UTC'):
        return sql(f"set timezone={quote(timezone)}; select to_char(window_start at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '/' || to_char(window_end at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') from public.monthly_allowance_window({quote(anchor)}, {quote(at)})")

    def overdue(self):
        # Persisted last-month spending; the actual server clock is unchanged.
        sql("update public.user_usage set analyses_used=200, refinements_remaining=1, period_started_at=period_started_at - interval '1 month'")

    def test_final_legacy_config_is_200(self):
        self.assertEqual(sql("select full_generation_allowance from public.usage_config where tier='plus'"), '200')

    def test_exact_boundary_and_no_early_reset(self):
        anchor = '2024-01-31T12:34:56Z'
        self.assertEqual(self.window(anchor, '2024-02-29T12:34:55Z'), '2024-01-31 12:34:56/2024-02-29 12:34:56')
        self.assertEqual(self.window(anchor, '2024-02-29T12:34:56Z'), '2024-02-29 12:34:56/2024-03-31 12:34:56')

    def test_short_month_does_not_drift_anchor(self):
        self.assertEqual(self.window('2025-01-31T10:00:00Z', '2025-03-31T10:00:00Z'), '2025-03-31 10:00:00/2025-04-30 10:00:00')
        self.assertEqual(self.window('2025-01-31T10:00:00Z', '2025-02-28T10:00:00Z'), '2025-02-28 10:00:00/2025-03-31 10:00:00')

    def test_utc_schedule_independent_of_dst_and_session_timezone(self):
        args = ['2026-01-08T08:00:00Z', '2026-03-08T08:00:00Z']
        self.assertEqual(self.window(*args, timezone='America/Chicago'), self.window(*args, timezone='Pacific/Auckland'))
        self.assertEqual(self.window(*args), '2026-03-08 08:00:00/2026-04-08 08:00:00')

    def test_all_12_annual_windows_are_monthly(self):
        for month in range(1, 13):
            at = f'2025-{month:02d}-15T10:00:00Z'
            next_at = f'2025-{month+1:02d}-15 10:00:00' if month < 12 else '2026-01-15 10:00:00'
            self.assertEqual(self.window('2025-01-15T10:00:00Z', at), at.replace('T', ' ').replace('Z', '') + '/' + next_at)

    def test_future_anchor_has_no_allowance_window(self):
        self.assertEqual(self.window('2099-01-01T00:00:00Z', '2026-10-18T00:00:00Z'), '')

    def test_annual_refreshes_without_annual_renewal_webhook(self):
        event(product='annual', period='2025-01-31T12:00:00Z')
        anchor = sql('select allowance_anchor_at from public.billing_accounts')
        self.overdue()
        self.assertEqual(usage()['remaining'], 200)
        self.assertEqual(usage()['refinements_remaining'], 0)
        self.assertEqual(sql('select allowance_anchor_at from public.billing_accounts'), anchor)
        reserve()
        self.assertEqual(usage()['remaining'], 199)

    def test_monthly_refreshes_when_read_or_reserved(self):
        event(); self.overdue()
        self.assertEqual(reserve()['outcome'], 'reserved')
        self.assertEqual(usage()['remaining'], 199)

    def test_missed_months_do_not_accumulate_allowance(self):
        event(product='annual', period='2024-01-01T00:00:00Z')
        sql("update public.user_usage set analyses_used=200, period_started_at='2024-01-01'")
        self.assertEqual(usage()['remaining'], 200)
        reserve()
        self.assertEqual(usage()['remaining'], 199)

    def test_renewal_and_plan_change_cannot_reset_early(self):
        event(); reserve()
        anchor = sql('select allowance_anchor_at from public.billing_accounts')
        periods = ['2026-09-01T00:00:00Z', '2026-10-01T00:00:00Z',
                   '2026-10-17T00:00:00Z', '2099-01-01T00:00:00Z']
        cases = [(kind, period) for kind in ['RENEWAL', 'PRODUCT_CHANGE', 'INITIAL_PURCHASE'] for period in periods]
        for i, (kind, period) in enumerate(cases):
            event(kind, at=f'2026-10-18T{i+3:02d}:00:00Z', period=period)
            self.assertEqual(usage()['remaining'], 199)
            self.assertEqual(sql('select allowance_anchor_at from public.billing_accounts'), anchor)

    def test_monthly_to_annual_change_preserves_current_spending(self):
        event(); reserve()
        event('PRODUCT_CHANGE', product='annual', period='2026-10-17T00:00:00Z', at='2026-10-18T03:00:00Z')
        self.assertEqual(usage()['remaining'], 199)
        self.assertEqual(usage()['product_id'], 'annual')

    def test_syncs_and_transfer_keep_fixed_anchor(self):
        event(); reserve()
        anchor = sql('select allowance_anchor_at from public.billing_accounts')
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda _: event('SERVER_SYNC', transaction='', period='2026-10-17T00:00:00Z'), range(3)))
        self.assertTrue(all(r['outcome'] == 'applied' for r in results))
        transfer()
        self.assertEqual(usage(B)['remaining'], 199)
        self.assertEqual(sql('select allowance_anchor_at from public.billing_accounts'), anchor)

    def test_expired_or_revoked_entitlement_cannot_refresh_overdue_month(self):
        for state in ["expires_at=now()-interval '1 second'", 'is_active=false']:
            with self.subTest(state=state):
                sql('truncate public.billing_accounts, public.revenuecat_webhook_events cascade')
                event(); self.overdue()
                sql('update public.subscription_entitlements set ' + state)
                self.assertFalse(usage()['subscribed'])
                self.assertEqual(reserve()['outcome'], 'subscription_required')
                self.assertEqual(sql('select analyses_used from public.user_usage'), '200')

    def test_missing_or_future_paid_start_is_locked(self):
        for period in [None, '2099-01-01T00:00:00Z']:
            sql('truncate public.billing_accounts, public.revenuecat_webhook_events cascade')
            event(period=period)
            self.assertFalse(usage()['subscribed'])
            self.assertEqual(reserve()['outcome'], 'subscription_required')
            self.assertEqual(sql('select count(*) from public.user_usage'), '0')

    def test_missing_anchor_recovers_with_verified_lifecycle(self):
        event(period=None)
        event('RENEWAL', at='2026-10-18T03:00:00Z')
        self.assertEqual(usage()['remaining'], 200)

    def test_concurrent_month_refresh_and_spending(self):
        event(product='annual'); self.overdue()
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: reserve(), range(6)))
        self.assertTrue(all(r['outcome'] == 'reserved' for r in results))
        self.assertEqual(usage()['remaining'], 194)

    def test_exact_200_limit_with_two_included_refinements(self):
        event()
        sql('update public.user_usage set analyses_used=199')
        self.assertEqual(reserve()['outcome'], 'reserved')
        self.assertEqual(reserve()['outcome'], 'usage_limit_exceeded')
        self.assertEqual(reserve(action='refinement')['outcome'], 'reserved')
        self.assertEqual(reserve(action='refinement')['outcome'], 'reserved')
        self.assertEqual(reserve(action='refinement')['outcome'], 'usage_limit_exceeded')
        self.assertEqual(usage()['remaining'], 0)

    def test_prior_month_analysis_refund_cannot_credit_new_month(self):
        event()
        old = reserve()['reservation_id']
        sql("update public.user_usage_requests set allowance_period_started_at=allowance_period_started_at-interval '1 month'")
        self.overdue()
        reserve()
        sql(f"select public.release_user_reservation({quote(old)})")
        self.assertEqual(usage()['remaining'], 199)
        self.assertEqual(usage()['refinements_remaining'], 2)

    def test_prior_month_refinement_refund_cannot_credit_new_month(self):
        event(); reserve()
        old = reserve(action='refinement')['reservation_id']
        # Emulate a reservation from the preceding window before refreshing.
        sql("update public.user_usage_requests set allowance_period_started_at=allowance_period_started_at-interval '1 month'")
        self.overdue()
        usage()
        sql(f"select public.release_user_reservation({quote(old)})")
        self.assertEqual(usage()['remaining'], 200)
        self.assertEqual(usage()['refinements_remaining'], 0)

    def test_concurrent_last_operation_cannot_exceed_200(self):
        event()
        sql('update public.user_usage set analyses_used=199')
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            outcomes = [r['outcome'] for r in pool.map(lambda _: reserve(), range(4))]
        self.assertEqual(outcomes.count('reserved'), 1)
        self.assertEqual(outcomes.count('usage_limit_exceeded'), 3)
        self.assertEqual(usage()['remaining'], 0)

    def test_same_month_refinement_refund_restores_one_credit(self):
        event(); reserve()
        current = reserve(action='refinement')['reservation_id']
        self.assertEqual(usage()['refinements_remaining'], 1)
        sql(f"select public.release_user_reservation({quote(current)})")
        self.assertEqual(usage()['remaining'], 199)
        self.assertEqual(usage()['refinements_remaining'], 2)

    def test_same_month_refund_preserves_existing_accounting(self):
        event()
        current = reserve()['reservation_id']
        sql(f"select public.release_user_reservation({quote(current)})")
        self.assertEqual(usage()['remaining'], 200)


class DurableAccountingTests(unittest.TestCase):
    def setUp(self):
        sql('truncate public.billing_accounts, public.revenuecat_webhook_events cascade')
        event()

    def rpc(self, name, reservation):
        return json.loads(sql(f'select public.{name}({quote(reservation)})'))

    def test_status_is_server_only(self):
        for role in ['anon', 'authenticated']:
            self.assertEqual(sql(f"select has_function_privilege('{role}', 'public.get_user_reservation_status(uuid)', 'execute')"), 'f')
        self.assertEqual(sql("select has_function_privilege('service_role', 'public.get_user_reservation_status(uuid)', 'execute')"), 't')

    def test_authoritative_states_and_idempotent_commit(self):
        r = reserve()['reservation_id']
        self.assertEqual(self.rpc('get_user_reservation_status', r)['status'], 'reserved')
        for _ in range(3):
            self.assertEqual(self.rpc('commit_user_reservation', r)['outcome'], 'committed')
        self.assertEqual(self.rpc('get_user_reservation_status', r)['status'], 'committed')
        self.assertEqual(self.rpc('release_user_reservation', r)['outcome'], 'noop')
        self.assertEqual(usage()['remaining'], 199)
        self.assertEqual(self.rpc('get_user_reservation_status', str(uuid.uuid4()))['status'], 'missing')

    def test_released_operation_cannot_commit(self):
        r = reserve()['reservation_id']
        self.rpc('release_user_reservation', r)
        self.assertEqual(self.rpc('get_user_reservation_status', r)['status'], 'released')
        self.assertEqual(self.rpc('commit_user_reservation', r)['outcome'], 'not_reserved')
        self.assertEqual(usage()['remaining'], 200)

    def test_unconfirmed_uncommitted_operation_expires_and_refunds_once(self):
        r = reserve()['reservation_id']
        sql("update public.user_usage_requests set expires_at=now()-interval '1 second'")
        reserve()
        self.assertEqual(self.rpc('get_user_reservation_status', r)['status'], 'released')
        self.assertEqual(usage()['remaining'], 199)
        self.assertEqual(self.rpc('release_user_reservation', r)['outcome'], 'noop')
        self.assertEqual(usage()['remaining'], 199)

    def test_committed_with_lost_ack_cannot_expire_to_free(self):
        r = reserve()['reservation_id']
        # Discard the successful mutation reply, as if the transport lost it.
        self.rpc('commit_user_reservation', r)
        sql("update public.user_usage_requests set expires_at=now()-interval '1 second'")
        reserve()
        self.assertEqual(self.rpc('get_user_reservation_status', r)['status'], 'committed')
        self.assertEqual(usage()['remaining'], 198)

    def test_duplicate_after_lost_ack_never_charges_again(self):
        request = str(uuid.uuid4())
        statement = f"select public.reserve_user_usage({quote(A)}, {quote(request)}, 'generation')"
        r = json.loads(sql(statement))['reservation_id']
        self.rpc('commit_user_reservation', r)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: json.loads(sql(statement)), range(4)))
        self.assertTrue(all(v['outcome'] == 'duplicate' and v['prior_status'] == 'committed' for v in results))
        self.assertEqual(usage()['remaining'], 199)

    def test_duplicate_uncertain_reserved_and_released_no_second_charge(self):
        request = str(uuid.uuid4())
        statement = f"select public.reserve_user_usage({quote(A)}, {quote(request)}, 'generation')"
        r = json.loads(sql(statement))['reservation_id']
        for state in ['reserved', 'released']:
            if state == 'released':
                self.rpc('release_user_reservation', r)
            duplicate = json.loads(sql(statement))
            self.assertEqual(duplicate['outcome'], 'duplicate')
            self.assertEqual(duplicate['prior_status'], state)
        self.assertEqual(usage()['remaining'], 200)

    def test_old_window_expiration_after_accounting_failure_cannot_credit_current(self):
        r = reserve()['reservation_id']
        sql("update public.user_usage_requests set allowance_period_started_at=allowance_period_started_at-interval '1 month', expires_at=now()-interval '1 second'")
        sql('update public.user_usage set analyses_used=10, refinements_remaining=0')
        reserve()
        self.assertEqual(self.rpc('get_user_reservation_status', r)['status'], 'released')
        self.assertEqual(usage()['remaining'], 189)
        self.assertEqual(usage()['refinements_remaining'], 2)

    def test_failed_refinement_expiration_restores_credit(self):
        charged = reserve()['reservation_id']
        self.rpc('commit_user_reservation', charged)
        r = reserve(action='refinement')['reservation_id']
        sql(f"update public.user_usage_requests set expires_at=now()-interval '1 second' where reservation_id={quote(r)}")
        # A new reservation drives stale cleanup; this refinement then uses one.
        reserve(action='refinement')
        self.assertEqual(self.rpc('get_user_reservation_status', r)['status'], 'released')
        self.assertEqual(usage()['remaining'], 199)
        self.assertEqual(usage()['refinements_remaining'], 1)

    def test_concurrent_commit_retries_near_limit(self):
        sql('update public.user_usage set analyses_used=199')
        r = reserve()['reservation_id']
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.rpc('commit_user_reservation', r), range(6)))
        self.assertTrue(all(v['outcome'] == 'committed' for v in results))
        self.assertEqual(reserve()['outcome'], 'usage_limit_exceeded')
        self.assertEqual(usage()['remaining'], 0)

    def test_old_window_commit_does_not_change_current_counters(self):
        r = reserve()['reservation_id']
        sql("update public.user_usage_requests set allowance_period_started_at=allowance_period_started_at-interval '1 month'")
        sql('update public.user_usage set analyses_used=5, refinements_remaining=0')
        self.assertEqual(self.rpc('commit_user_reservation', r)['outcome'], 'committed')
        self.assertEqual(usage()['remaining'], 195)
        self.assertEqual(usage()['refinements_remaining'], 0)

if __name__ == '__main__':
    # No supplied DSN, no hosted project, generated disposable database name.
    sql(f'create database {DB}', database='postgres')
    try:
        for role in ['anon', 'authenticated', 'service_role']:
            sql(f"do $$ begin if not exists (select from pg_roles where rolname='{role}') then create role {role}; end if; end $$;")
        sql("create schema auth; create table auth.users(id uuid primary key); "
            f"insert into auth.users values ('{A}'),('{B}'),('{C}');")
        sql((ROOT / 'supabase/migrations/20260906200000_quota_enforcement.sql').read_text())
        sql((ROOT / 'supabase/migrations/20261018000000_mandatory_subscriptions.sql').read_text())
        result = unittest.main(verbosity=2, exit=False).result
    finally:
        sql(f'drop database {DB}', database='postgres')
    sys.exit(not result.wasSuccessful())
