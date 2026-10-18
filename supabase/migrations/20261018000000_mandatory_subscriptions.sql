-- Mandatory subscriptions for authenticated Supabase users.
--
-- This is intentionally additive. The installation/free-tier tables remain
-- available for rollback and historical migrations, but app-facing functions
-- use only the user/billing-account RPCs below.

create table public.billing_accounts (
  id uuid primary key default gen_random_uuid(),
  original_transaction_id text not null unique,
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index billing_accounts_one_per_user_idx
  on public.billing_accounts(user_id) where user_id is not null;

create table public.billing_account_aliases (
  app_user_id text primary key,
  billing_account_id uuid not null
    references public.billing_accounts(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index billing_account_aliases_account_idx
  on public.billing_account_aliases(billing_account_id);

create table public.subscription_entitlements (
  billing_account_id uuid primary key
    references public.billing_accounts(id) on delete cascade,
  entitlement_id text not null,
  product_id text,
  environment text not null,
  store text not null,
  is_active boolean not null default false,
  period_started_at timestamptz,
  expires_at timestamptz,
  last_event_at timestamptz not null,
  last_event_id text not null,
  updated_at timestamptz not null default now(),
  check (not is_active or expires_at is not null)
);

create table public.revenuecat_webhook_events (
  event_id text primary key,
  event_type text not null,
  event_at timestamptz not null,
  original_transaction_id text,
  app_user_id text,
  status text not null
    check (status in ('applied', 'duplicate', 'ignored', 'rejected', 'stale')),
  reason text,
  received_at timestamptz not null default now()
);

create index revenuecat_webhook_events_transaction_idx
  on public.revenuecat_webhook_events(original_transaction_id, event_at desc);

create table public.user_usage (
  billing_account_id uuid primary key
    references public.billing_accounts(id) on delete cascade,
  analyses_used integer not null default 0 check (analyses_used >= 0),
  refinements_remaining integer not null default 0
    check (refinements_remaining >= 0),
  period_started_at timestamptz not null,
  period_ends_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.user_usage_requests (
  reservation_id uuid primary key default gen_random_uuid(),
  billing_account_id uuid not null
    references public.billing_accounts(id) on delete cascade,
  request_id uuid not null,
  action_kind text not null check (action_kind in ('generation', 'refinement')),
  charge_kind text not null check (charge_kind in ('analysis', 'free_refinement')),
  status text not null default 'reserved'
    check (status in ('reserved', 'committed', 'released')),
  prev_analyses_used integer not null,
  prev_refinements_remaining integer not null,
  created_at timestamptz not null default now(),
  committed_at timestamptz,
  released_at timestamptz,
  -- Longer than the maximum two-attempt OpenAI operation. A reservation
  -- must never be released while its edge request can still be running.
  expires_at timestamptz not null default now() + interval '10 minutes',
  unique (billing_account_id, request_id)
);

create index user_usage_requests_stale_idx
  on public.user_usage_requests(billing_account_id, status, expires_at);

alter table public.billing_accounts enable row level security;
alter table public.billing_account_aliases enable row level security;
alter table public.subscription_entitlements enable row level security;
alter table public.revenuecat_webhook_events enable row level security;
alter table public.user_usage enable row level security;
alter table public.user_usage_requests enable row level security;

revoke all on table public.billing_accounts from public, anon, authenticated;
revoke all on table public.billing_account_aliases from public, anon, authenticated;
revoke all on table public.subscription_entitlements from public, anon, authenticated;
revoke all on table public.revenuecat_webhook_events from public, anon, authenticated;
revoke all on table public.user_usage from public, anon, authenticated;
revoke all on table public.user_usage_requests from public, anon, authenticated;

create function public.user_usage_status(p_user_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_account public.billing_accounts;
  v_entitlement public.subscription_entitlements;
  v_usage public.user_usage;
  v_limit constant integer := 150;
begin
  select * into v_account
  from public.billing_accounts
  where user_id = p_user_id;

  if not found then
    return jsonb_build_object(
      'subscribed', false, 'remaining', 0, 'limit', v_limit,
      'refinements_remaining', 0
    );
  end if;

  select * into v_entitlement
  from public.subscription_entitlements
  where billing_account_id = v_account.id;

  if not found or not v_entitlement.is_active
     or (v_entitlement.expires_at is not null
         and v_entitlement.expires_at <= now()) then
    return jsonb_build_object(
      'subscribed', false, 'remaining', 0, 'limit', v_limit,
      'refinements_remaining', 0,
      'expires_at', v_entitlement.expires_at
    );
  end if;

  select * into v_usage
  from public.user_usage
  where billing_account_id = v_account.id;

  return jsonb_build_object(
    'subscribed', true,
    'remaining', greatest(0, v_limit - coalesce(v_usage.analyses_used, 0)),
    'limit', v_limit,
    'refinements_remaining', coalesce(v_usage.refinements_remaining, 0),
    'expires_at', v_entitlement.expires_at,
    'product_id', v_entitlement.product_id
  );
end;
$$;

-- Atomic server-only entitlement ingestion. The caller has already validated
-- app/environment/store/entitlement values. Ordering and deduplication are
-- enforced again here, in the same transaction as the entitlement update.
create function public.apply_revenuecat_event(
  p_event_id text,
  p_event_type text,
  p_event_at timestamptz,
  p_original_transaction_id text,
  p_app_user_id text,
  p_user_id uuid,
  p_aliases text[],
  p_entitlement_id text,
  p_product_id text,
  p_environment text,
  p_store text,
  p_is_active boolean,
  p_period_started_at timestamptz,
  p_expires_at timestamptz,
  p_reset_period boolean
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_account public.billing_accounts;
  v_entitlement public.subscription_entitlements;
  v_alias text;
begin
  if nullif(p_event_id, '') is null or p_event_at is null then
    raise exception 'event id and timestamp are required';
  end if;

  insert into public.revenuecat_webhook_events(
    event_id, event_type, event_at, original_transaction_id, app_user_id, status
  ) values (
    p_event_id, p_event_type, p_event_at, nullif(p_original_transaction_id, ''),
    nullif(p_app_user_id, ''), 'ignored'
  )
  on conflict (event_id) do nothing;

  if not found then
    return jsonb_build_object('outcome', 'duplicate');
  end if;

  if nullif(p_original_transaction_id, '') is not null then
    -- subscription-sync creates a provisional account because RevenueCat's
    -- subscriber REST API does not expose Apple's original_transaction_id.
    -- The first lifecycle webhook upgrades that row in place, preserving
    -- usage while removing the provisional identity.
    if p_user_id is not null
       and p_original_transaction_id not like 'pending:%' then
      update public.billing_accounts
      set original_transaction_id = p_original_transaction_id,
          updated_at = now()
      where user_id = p_user_id
        and original_transaction_id = 'pending:' || p_user_id::text
        and not exists (
          select 1 from public.billing_accounts
          where original_transaction_id = p_original_transaction_id
        )
      returning * into v_account;
    end if;

    if v_account.id is null then
      insert into public.billing_accounts(original_transaction_id)
      values (p_original_transaction_id)
    on conflict (original_transaction_id) do update
        set updated_at = now()
    returning * into v_account;
    end if;
  else
    select ba.* into v_account
    from public.billing_account_aliases a
    join public.billing_accounts ba on ba.id = a.billing_account_id
    where a.app_user_id = any(coalesce(p_aliases, array[]::text[]))
       or a.app_user_id = p_app_user_id
    limit 1
    for update of ba;
  end if;

  if not found then
    update public.revenuecat_webhook_events
    set status = 'ignored', reason = 'billing_account_not_resolved'
    where event_id = p_event_id;
    return jsonb_build_object('outcome', 'ignored');
  end if;

  select * into v_entitlement
  from public.subscription_entitlements
  where billing_account_id = v_account.id
  for update;

  if p_event_type not in ('TRANSFER', 'SUBSCRIBER_ALIAS')
     and found and (p_event_at, p_event_id) <=
      (v_entitlement.last_event_at, v_entitlement.last_event_id) then
    update public.revenuecat_webhook_events
    set status = 'stale', reason = 'older_than_applied_state'
    where event_id = p_event_id;
    return jsonb_build_object('outcome', 'stale');
  end if;

  if p_user_id is not null then
    -- RevenueCat transfers move the stable Apple billing account instead of
    -- creating a second allowance. The partial unique index prevents one
    -- Supabase user from owning two active billing accounts.
    insert into public.user_usage(
      billing_account_id, analyses_used, refinements_remaining,
      period_started_at, period_ends_at
    )
    select
      v_account.id, u.analyses_used, u.refinements_remaining,
      u.period_started_at, u.period_ends_at
    from public.billing_accounts prior
    join public.user_usage u on u.billing_account_id = prior.id
    where prior.user_id = p_user_id and prior.id <> v_account.id
    on conflict (billing_account_id) do update set
      -- Never let a restore/transfer reset subscriber spending protection.
      analyses_used = greatest(
        public.user_usage.analyses_used, excluded.analyses_used
      ),
      refinements_remaining = least(
        public.user_usage.refinements_remaining,
        excluded.refinements_remaining
      ),
      period_started_at = greatest(
        public.user_usage.period_started_at, excluded.period_started_at
      ),
      period_ends_at = greatest(
        public.user_usage.period_ends_at, excluded.period_ends_at
      ),
      updated_at = now();

    update public.billing_accounts
    set user_id = null, updated_at = now()
    where user_id = p_user_id and id <> v_account.id;

    update public.billing_accounts
    set user_id = p_user_id, updated_at = now()
    where id = v_account.id
    returning * into v_account;
  end if;

  foreach v_alias in array coalesce(p_aliases, array[]::text[]) loop
    if nullif(v_alias, '') is not null then
      insert into public.billing_account_aliases(app_user_id, billing_account_id)
      values (v_alias, v_account.id)
      on conflict (app_user_id) do update
        set billing_account_id = excluded.billing_account_id;
    end if;
  end loop;

  if nullif(p_app_user_id, '') is not null then
    insert into public.billing_account_aliases(app_user_id, billing_account_id)
    values (p_app_user_id, v_account.id)
    on conflict (app_user_id) do update
      set billing_account_id = excluded.billing_account_id;
  end if;

  if p_event_type in ('TRANSFER', 'SUBSCRIBER_ALIAS') then
    update public.revenuecat_webhook_events
    set status = 'applied', reason = 'ownership_updated'
    where event_id = p_event_id;
    return jsonb_build_object(
      'outcome', 'applied', 'usage', public.user_usage_status(p_user_id)
    );
  end if;

  insert into public.subscription_entitlements(
    billing_account_id, entitlement_id, product_id, environment, store,
    is_active, period_started_at, expires_at, last_event_at, last_event_id
  ) values (
    v_account.id, p_entitlement_id, p_product_id, p_environment, p_store,
    p_is_active, p_period_started_at, p_expires_at, p_event_at, p_event_id
  )
  on conflict (billing_account_id) do update set
    entitlement_id = excluded.entitlement_id,
    product_id = excluded.product_id,
    environment = excluded.environment,
    store = excluded.store,
    is_active = excluded.is_active,
    period_started_at = excluded.period_started_at,
    expires_at = excluded.expires_at,
    last_event_at = excluded.last_event_at,
    last_event_id = excluded.last_event_id,
    updated_at = now();

  if p_is_active then
    -- First insert may use p_event_at only as a placeholder start. Resets
    -- require a trusted p_period_started_at that is strictly newer than the
    -- stored period. Never treat now()/p_event_at as a new billing month.
    insert into public.user_usage(
      billing_account_id, period_started_at, period_ends_at
    ) values (
      v_account.id, coalesce(p_period_started_at, p_event_at), p_expires_at
    )
    on conflict (billing_account_id) do update set
      analyses_used = case
        when p_reset_period
          and p_period_started_at is not null
          and p_period_started_at > public.user_usage.period_started_at
        then 0 else public.user_usage.analyses_used end,
      refinements_remaining = case
        when p_reset_period
          and p_period_started_at is not null
          and p_period_started_at > public.user_usage.period_started_at
        then 0 else public.user_usage.refinements_remaining end,
      period_started_at = case
        when p_reset_period
          and p_period_started_at is not null
          and p_period_started_at > public.user_usage.period_started_at
        then p_period_started_at
        else public.user_usage.period_started_at
      end,
      period_ends_at = coalesce(p_expires_at, public.user_usage.period_ends_at),
      updated_at = now();
  end if;

  update public.revenuecat_webhook_events
  set status = 'applied'
  where event_id = p_event_id;

  return jsonb_build_object(
    'outcome', 'applied', 'usage', public.user_usage_status(p_user_id)
  );
end;
$$;

create function public.release_user_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_res public.user_usage_requests;
  v_usage public.user_usage;
begin
  select * into v_res from public.user_usage_requests
  where reservation_id = p_reservation_id for update;

  if not found or v_res.status <> 'reserved' then
    return jsonb_build_object('outcome', 'noop');
  end if;

  select * into v_usage from public.user_usage
  where billing_account_id = v_res.billing_account_id for update;

  if v_res.charge_kind = 'free_refinement' then
    update public.user_usage
    set refinements_remaining = least(2, refinements_remaining + 1),
        updated_at = now()
    where billing_account_id = v_res.billing_account_id;
  elsif v_usage.analyses_used = v_res.prev_analyses_used + 1 then
    update public.user_usage
    set analyses_used = v_res.prev_analyses_used,
        refinements_remaining = v_res.prev_refinements_remaining,
        updated_at = now()
    where billing_account_id = v_res.billing_account_id;
  else
    update public.user_usage
    set analyses_used = greatest(0, analyses_used - 1), updated_at = now()
    where billing_account_id = v_res.billing_account_id;
  end if;

  update public.user_usage_requests
  set status = 'released', released_at = now()
  where reservation_id = p_reservation_id;

  return jsonb_build_object('outcome', 'released');
end;
$$;

create function public.reserve_user_usage(
  p_user_id uuid,
  p_request_id uuid,
  p_action_kind text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_account public.billing_accounts;
  v_entitlement public.subscription_entitlements;
  v_usage public.user_usage;
  v_existing public.user_usage_requests;
  v_stale uuid;
  v_charge text;
  v_reservation_id uuid;
  v_limit constant integer := 150;
begin
  if p_action_kind not in ('generation', 'refinement') then
    raise exception 'invalid action_kind %', p_action_kind;
  end if;

  select * into v_account from public.billing_accounts
  where user_id = p_user_id for update;
  if not found then
    return jsonb_build_object(
      'outcome', 'subscription_required',
      'usage', public.user_usage_status(p_user_id)
    );
  end if;

  select * into v_entitlement from public.subscription_entitlements
  where billing_account_id = v_account.id;
  if not found or not v_entitlement.is_active
     or (v_entitlement.expires_at is not null
         and v_entitlement.expires_at <= now()) then
    return jsonb_build_object(
      'outcome', 'subscription_required',
      'usage', public.user_usage_status(p_user_id)
    );
  end if;

  insert into public.user_usage(
    billing_account_id, period_started_at, period_ends_at
  ) values (
    v_account.id, coalesce(v_entitlement.period_started_at, now()),
    v_entitlement.expires_at
  ) on conflict (billing_account_id) do nothing;

  select * into v_usage from public.user_usage
  where billing_account_id = v_account.id for update;

  select * into v_existing from public.user_usage_requests
  where billing_account_id = v_account.id and request_id = p_request_id;
  if found then
    return jsonb_build_object(
      'outcome', 'duplicate', 'reservation_id', v_existing.reservation_id,
      'prior_status', v_existing.status,
      'usage', public.user_usage_status(p_user_id)
    );
  end if;

  for v_stale in
    select reservation_id from public.user_usage_requests
    where billing_account_id = v_account.id
      and status = 'reserved' and expires_at < now()
  loop
    perform public.release_user_reservation(v_stale);
  end loop;

  select * into v_usage from public.user_usage
  where billing_account_id = v_account.id;
  v_charge := case
    when p_action_kind = 'refinement' and v_usage.refinements_remaining > 0
      then 'free_refinement'
    else 'analysis'
  end;

  if v_charge = 'analysis' and v_usage.analyses_used >= v_limit then
    return jsonb_build_object(
      'outcome', 'usage_limit_exceeded',
      'usage', public.user_usage_status(p_user_id)
    );
  end if;

  insert into public.user_usage_requests(
    billing_account_id, request_id, action_kind, charge_kind,
    prev_analyses_used, prev_refinements_remaining
  ) values (
    v_account.id, p_request_id, p_action_kind, v_charge,
    v_usage.analyses_used, v_usage.refinements_remaining
  ) returning reservation_id into v_reservation_id;

  if v_charge = 'analysis' then
    update public.user_usage
    set analyses_used = analyses_used + 1, refinements_remaining = 2,
        updated_at = now()
    where billing_account_id = v_account.id;
  else
    update public.user_usage
    set refinements_remaining = refinements_remaining - 1, updated_at = now()
    where billing_account_id = v_account.id;
  end if;

  return jsonb_build_object(
    'outcome', 'reserved', 'reservation_id', v_reservation_id,
    'usage', public.user_usage_status(p_user_id)
  );
end;
$$;

create function public.commit_user_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_res public.user_usage_requests;
  v_user_id uuid;
begin
  update public.user_usage_requests
  set status = 'committed', committed_at = now()
  where reservation_id = p_reservation_id and status = 'reserved'
  returning * into v_res;

  if not found then
    select * into v_res from public.user_usage_requests
    where reservation_id = p_reservation_id;
  end if;

  select user_id into v_user_id from public.billing_accounts
  where id = v_res.billing_account_id;

  return jsonb_build_object(
    'outcome', case when v_res.status = 'committed'
      then 'committed' else 'not_reserved' end,
    'usage', public.user_usage_status(v_user_id)
  );
end;
$$;

create function public.get_user_usage(p_user_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select public.user_usage_status(p_user_id)
$$;

revoke execute on function public.user_usage_status(uuid)
  from public, anon, authenticated;
revoke execute on function public.apply_revenuecat_event(
  text, text, timestamptz, text, text, uuid, text[], text, text, text, text,
  boolean, timestamptz, timestamptz, boolean
) from public, anon, authenticated;
revoke execute on function public.release_user_reservation(uuid)
  from public, anon, authenticated;
revoke execute on function public.reserve_user_usage(uuid, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.commit_user_reservation(uuid)
  from public, anon, authenticated;
revoke execute on function public.get_user_usage(uuid)
  from public, anon, authenticated;

grant execute on function public.user_usage_status(uuid) to service_role;
grant execute on function public.apply_revenuecat_event(
  text, text, timestamptz, text, text, uuid, text[], text, text, text, text,
  boolean, timestamptz, timestamptz, boolean
) to service_role;
grant execute on function public.release_user_reservation(uuid) to service_role;
grant execute on function public.reserve_user_usage(uuid, uuid, text)
  to service_role;
grant execute on function public.commit_user_reservation(uuid)
  to service_role;
grant execute on function public.get_user_usage(uuid) to service_role;
