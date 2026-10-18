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
          active=True):
    args = [id or str(uuid.uuid4()), kind, at, transaction,
            user or '', user, aliases if aliases is not None else [user],
            'plus', 'monthly', 'SANDBOX', 'APP_STORE', active,
            '2026-10-01T00:00:00Z', '2099-11-01T00:00:00Z' if active else None,
            kind == 'INITIAL_PURCHASE', sources or []]
    return json.loads(sql('select public.apply_revenuecat_event(' +
        ','.join(map(quote, args)) + ')'))

def usage(user=A):
    return json.loads(sql(f'select public.get_user_usage({quote(user)})'))

def reserve(user=A):
    return json.loads(sql('select public.reserve_user_usage(' +
        ','.join(map(quote, [user, str(uuid.uuid4()), 'generation'])) + ')'))

def transfer(user=B, sources=None, **kwargs):
    return event('TRANSFER', user=user, transaction='',
                 sources=sources or [A], at=kwargs.pop('at', '2026-10-18T02:00:00Z'), **kwargs)

class OwnershipTests(unittest.TestCase):
    def setUp(self):
        sql('truncate public.billing_accounts, public.revenuecat_webhook_events cascade')

    def test_new_purchase(self):
        self.assertEqual(event()['outcome'], 'applied')
        self.assertEqual(usage()['remaining'], 150)

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
        self.assertEqual(usage()['remaining'], 149)

    def test_different_identity_restore(self):
        event(); reserve()
        self.assertEqual(event('SERVER_SYNC', user=B, transaction='')['outcome'], 'pending_verification')
        self.assertFalse(usage(B)['subscribed'])
        transfer()
        self.assertEqual(usage(B)['remaining'], 149)
        self.assertEqual(sql('select count(*) from public.billing_accounts'), '1')

    def test_75_consumed_and_refinements_preserved(self):
        event()
        sql('update public.user_usage set analyses_used=75, refinements_remaining=1')
        transfer()
        self.assertEqual(usage(B)['remaining'], 75)
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
        self.assertEqual(usage(B)['remaining'], 149)
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
        self.assertEqual(usage()['remaining'], 149)
        self.assertFalse(usage(B)['subscribed'])

    def test_alias_event_cannot_grant_another_identity(self):
        event()
        self.assertEqual(event('SUBSCRIBER_ALIAS', user=B, transaction='', aliases=[A, B])['outcome'], 'pending_verification')
        self.assertEqual(reserve(B)['outcome'], 'subscription_required')

if __name__ == '__main__':
    # No supplied DSN, no hosted project, generated disposable database name.
    sql(f'create database {DB}', database='postgres')
    try:
        for role in ['anon', 'authenticated', 'service_role']:
            sql(f"do $$ begin if not exists (select from pg_roles where rolname='{role}') then create role {role}; end if; end $$;")
        sql("create schema auth; create table auth.users(id uuid primary key); "
            f"insert into auth.users values ('{A}'),('{B}'),('{C}');")
        sql((ROOT / 'supabase/migrations/20261018000000_mandatory_subscriptions.sql').read_text())
        result = unittest.main(verbosity=2, exit=False).result
    finally:
        sql(f'drop database {DB}', database='postgres')
    sys.exit(not result.wasSuccessful())
