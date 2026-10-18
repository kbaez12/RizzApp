-- Mandatory subscriptions for authenticated Supabase users.
--
-- This is intentionally additive. The installation/free-tier tables remain
-- available for rollback and historical migrations, but app-facing functions
-- use only the user/billing-account RPCs below.

create table public.billing_accounts (
  id uuid primary key default gen_random_uuid(),
  original_transaction_id text not null unique
    check (original_transaction_id <> '' and original_transaction_id not like 'pending:%'),
  allowance_anchor_at timestamptz,
  ownership_event_at timestamptz,
  ownership_event_id text,
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index billing_accounts_one_per_user_idx
  on public.billing_accounts(user_id) where user_id is not null;

create table public.billing_account_aliases (
  app_user_id text not null,
  billing_account_id uuid not null
    references public.billing_accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (app_user_id, billing_account_id)
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
    check (status in ('applied', 'duplicate', 'ignored', 'rejected', 'stale', 'pending')),
  reason text,
  source_aliases text[] not null default array[]::text[],
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
  allowance_period_started_at timestamptz not null,
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
  v_limit constant integer := 200;
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

  if not found then
    return jsonb_build_object('subscribed', false, 'remaining', 0,
      'limit', v_limit, 'refinements_remaining', 0);
  end if;

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

-- Calendar windows use the original UTC anchor, retaining the original day
-- after short months (Jan 31 -> Feb 28/29 -> Mar 31). End is exclusive.
create function public.monthly_allowance_window(p_anchor timestamptz, p_at timestamptz)
returns table(window_start timestamptz, window_end timestamptz)
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
  v_anchor timestamp := p_anchor at time zone 'UTC';
  v_at timestamp := p_at at time zone 'UTC';
  v_months integer;
begin
  if p_at < p_anchor then return; end if;
  v_months := (extract(year from v_at)::integer - extract(year from v_anchor)::integer) * 12
    + extract(month from v_at)::integer - extract(month from v_anchor)::integer;
  if v_anchor + make_interval(months => v_months) > v_at then
    v_months := v_months - 1;
  end if;
  window_start := (v_anchor + make_interval(months => v_months)) at time zone 'UTC';
  window_end := (v_anchor + make_interval(months => v_months + 1)) at time zone 'UTC';
  return next;
end;
$$;

-- Server-only: callers cannot supply a reset date or move the fixed anchor.
-- Both annual and monthly paid entitlements use exactly the same schedule.
create function public.refresh_billing_allowance(p_account_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_account public.billing_accounts;
  v_entitlement public.subscription_entitlements;
  v_start timestamptz;
  v_end timestamptz;
begin
  select * into v_account from public.billing_accounts
  where id = p_account_id for update;
  if not found or v_account.user_id is null or v_account.allowance_anchor_at is null then
    return;
  end if;
  select * into v_entitlement from public.subscription_entitlements
  where billing_account_id = p_account_id;
  if not found or not v_entitlement.is_active or v_entitlement.expires_at <= now() then
    return;
  end if;
  select window_start, window_end into v_start, v_end
  from public.monthly_allowance_window(v_account.allowance_anchor_at, now());
  if not found then return; end if;
  insert into public.user_usage(billing_account_id, period_started_at, period_ends_at)
  values (p_account_id, v_start, least(v_end, v_entitlement.expires_at))
  on conflict (billing_account_id) do update set
    analyses_used = case when excluded.period_started_at > public.user_usage.period_started_at
      then 0 else public.user_usage.analyses_used end,
    refinements_remaining = case when excluded.period_started_at > public.user_usage.period_started_at
      then 0 else public.user_usage.refinements_remaining end,
    period_started_at = greatest(public.user_usage.period_started_at, excluded.period_started_at),
    period_ends_at = excluded.period_ends_at,
    updated_at = now();
end;
$$;

revoke execute on function public.monthly_allowance_window(timestamptz, timestamptz)
  from public, anon, authenticated;
revoke execute on function public.refresh_billing_allowance(uuid)
  from public, anon, authenticated;
grant execute on function public.monthly_allowance_window(timestamptz, timestamptz) to service_role;
grant execute on function public.refresh_billing_allowance(uuid) to service_role;

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
  p_reset_period boolean,
  p_source_aliases text[] default array[]::text[]
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
  v_ids uuid[];
  v_all_aliases text[] := array_append(coalesce(p_aliases, array[]::text[]), p_app_user_id);
  v_pending boolean;
begin
  if nullif(p_event_id, '') is null or p_event_at is null then
    raise exception 'event id and timestamp are required';
  end if;
  -- Serializes absent-row resolution, competing transfers and duplicate events.
  -- AI reservations serialize with ownership changes on the account row lock.
  perform pg_advisory_xact_lock(718031810);
  insert into public.revenuecat_webhook_events(
    event_id, event_type, event_at, original_transaction_id, app_user_id,
    status, source_aliases
  ) values (
    p_event_id, p_event_type, p_event_at, nullif(p_original_transaction_id, ''),
    nullif(p_app_user_id, ''), 'pending', coalesce(p_source_aliases, array[]::text[])
  ) on conflict (event_id) do nothing;
  if not found and exists (
    select 1 from public.revenuecat_webhook_events
    where event_id = p_event_id and status <> 'pending'
  ) then
    return jsonb_build_object('outcome', 'duplicate');
  end if;

  if p_event_type = 'SERVER_SYNC' then
    -- Sync cannot create an account, follow historical aliases or move ownership.
    select * into v_account from public.billing_accounts
    where user_id = p_user_id for update;
    if not found then
      return jsonb_build_object('outcome', 'pending_verification');
    end if;
    select * into v_entitlement from public.subscription_entitlements
    where billing_account_id = v_account.id;
    if not found or (p_is_active and
        (v_entitlement.product_id is distinct from p_product_id or
         v_entitlement.environment <> p_environment or
         v_entitlement.store <> p_store)) then
      update public.subscription_entitlements set is_active = false
      where billing_account_id = v_account.id;
      return jsonb_build_object('outcome', 'pending_verification');
    end if;
    update public.subscription_entitlements
    set is_active = p_is_active, expires_at = p_expires_at, updated_at = now()
    where billing_account_id = v_account.id;
    -- Server time may advance a due month; sync timestamps never reset it.
    perform public.refresh_billing_allowance(v_account.id);
    update public.revenuecat_webhook_events set status = 'applied'
    where event_id = p_event_id;
    return jsonb_build_object('outcome', 'applied',
      'usage', public.user_usage_status(p_user_id));
  end if;

  if p_event_type = 'TRANSFER' then
    -- Only source aliases identify the transferred purchase. Keep all historical
    -- associations so ambiguity is detected instead of selecting an arbitrary row.
    select array_agg(distinct billing_account_id) into v_ids
    from public.billing_account_aliases
    where app_user_id = any(coalesce(p_source_aliases, array[]::text[]));
    if coalesce(cardinality(v_ids), 0) <> 1 or p_user_id is null then
      update public.billing_accounts set user_id = null, updated_at = now()
      where id = any(v_ids);
      update public.revenuecat_webhook_events
      set reason = 'ambiguous_or_missing_transfer_ownership'
      where event_id = p_event_id;
      return jsonb_build_object('outcome', 'pending_verification');
    end if;
    select * into v_account from public.billing_accounts
    where id = v_ids[1] for update;
    if p_event_at = v_account.ownership_event_at
       and p_event_id <> v_account.ownership_event_id then
      -- Event IDs are opaque: lexical order cannot establish which of two
      -- simultaneous ownership events happened last.
      update public.billing_accounts set user_id = null where id = v_account.id;
      return jsonb_build_object('outcome', 'pending_verification');
    end if;
    if (p_event_at, p_event_id) <=
       (v_account.ownership_event_at, v_account.ownership_event_id) then
      update public.revenuecat_webhook_events set status = 'stale'
      where event_id = p_event_id;
      return jsonb_build_object('outcome', 'stale');
    end if;
    select * into v_entitlement from public.subscription_entitlements
    where billing_account_id = v_account.id;
    if not found or (p_is_active and
        (v_entitlement.product_id is distinct from p_product_id or
         v_entitlement.environment <> p_environment or
         v_entitlement.store <> p_store)) then
      update public.billing_accounts set user_id = null where id = v_account.id;
      return jsonb_build_object('outcome', 'pending_verification');
    end if;
    -- A different destination purchase stays separate, with its usage intact.
    update public.billing_accounts set user_id = null, updated_at = now()
    where user_id = p_user_id and id <> v_account.id;
    update public.billing_accounts
    set user_id = p_user_id, ownership_event_at = p_event_at,
        ownership_event_id = p_event_id, updated_at = now()
    where id = v_account.id;
    update public.subscription_entitlements
    set is_active = p_is_active, expires_at = p_expires_at, updated_at = now()
    where billing_account_id = v_account.id;
    foreach v_alias in array v_all_aliases loop
      if nullif(v_alias, '') is not null then
        insert into public.billing_account_aliases(app_user_id, billing_account_id)
        values (v_alias, v_account.id) on conflict do nothing;
      end if;
    end loop;
    perform public.refresh_billing_allowance(v_account.id);
    update public.revenuecat_webhook_events set status = 'applied', reason = 'ownership_updated'
    where event_id = p_event_id;
    return jsonb_build_object('outcome', 'applied',
      'usage', public.user_usage_status(p_user_id));
  end if;

  if p_event_type = 'SUBSCRIBER_ALIAS' or
     nullif(p_original_transaction_id, '') is null or
     p_original_transaction_id like 'pending:%' then
    return jsonb_build_object('outcome', 'pending_verification');
  end if;
  -- Only a trusted lifecycle transaction can create an allowance.
  insert into public.billing_accounts(original_transaction_id)
  values (p_original_transaction_id)
  on conflict (original_transaction_id) do update set updated_at = now()
  returning * into v_account;
  select * into v_entitlement from public.subscription_entitlements
  where billing_account_id = v_account.id for update;
  if found and (p_event_at, p_event_id) <=
      (v_entitlement.last_event_at, v_entitlement.last_event_id) then
    update public.revenuecat_webhook_events set status = 'stale'
    where event_id = p_event_id;
    return jsonb_build_object('outcome', 'stale');
  end if;
  select exists (
    select 1 from public.revenuecat_webhook_events e
    where e.event_type = 'TRANSFER' and e.status = 'pending'
      and e.source_aliases && v_all_aliases
  ) into v_pending;
  -- Lifecycle events cannot reclaim an account after transfer or detach.
  -- A pending early transfer blocks a late purchase from unlocking its source.
  if v_account.ownership_event_at is null and not v_pending and p_user_id is not null then
    if not exists (select 1 from public.billing_accounts
                   where user_id = p_user_id and id <> v_account.id) then
      update public.billing_accounts
      set user_id = p_user_id, ownership_event_at = p_event_at,
          ownership_event_id = p_event_id where id = v_account.id;
    end if;
  end if;
  foreach v_alias in array v_all_aliases loop
    if nullif(v_alias, '') is not null then
      insert into public.billing_account_aliases(app_user_id, billing_account_id)
      values (v_alias, v_account.id) on conflict do nothing;
    end if;
  end loop;
  if v_account.ownership_event_at is not null and
     (v_account.user_id is distinct from p_user_id or
      (p_event_at, p_event_id) <=
      (v_account.ownership_event_at, v_account.ownership_event_id)) then
    update public.revenuecat_webhook_events set status = 'stale'
    where event_id = p_event_id;
    return jsonb_build_object('outcome', 'stale');
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

  -- The first usable, verified paid start fixes the allowance schedule.
  -- Renewal, sync, transfer and product changes never re-anchor it.
  if p_is_active and p_period_started_at is not null
     and p_period_started_at <= now() and p_period_started_at < p_expires_at then
    update public.billing_accounts
    set allowance_anchor_at = p_period_started_at
    where id = v_account.id and allowance_anchor_at is null;
  end if;
  perform public.refresh_billing_allowance(v_account.id);

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

  if v_usage.period_started_at is distinct from v_res.allowance_period_started_at then
    -- This reservation belongs to an older month: do not credit the new month.
    null;
  elsif v_res.charge_kind = 'free_refinement' then
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
  v_limit constant integer := 200;
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

  perform public.refresh_billing_allowance(v_account.id);

  select * into v_usage from public.user_usage
  where billing_account_id = v_account.id for update;
  if not found then
    return jsonb_build_object('outcome', 'subscription_required',
      'usage', public.user_usage_status(p_user_id));
  end if;

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
    allowance_period_started_at, prev_analyses_used, prev_refinements_remaining
  ) values (
    v_account.id, p_request_id, p_action_kind, v_charge,
    v_usage.period_started_at, v_usage.analyses_used, v_usage.refinements_remaining
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
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_account_id uuid;
begin
  select id into v_account_id from public.billing_accounts
  where user_id = p_user_id for update;
  if found then
    perform public.refresh_billing_allowance(v_account_id);
  end if;
  return public.user_usage_status(p_user_id);
end;
$$;

revoke execute on function public.user_usage_status(uuid)
  from public, anon, authenticated;
revoke execute on function public.apply_revenuecat_event(
  text, text, timestamptz, text, text, uuid, text[], text, text, text, text,
  boolean, timestamptz, timestamptz, boolean, text[]
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
  boolean, timestamptz, timestamptz, boolean, text[]
) to service_role;
grant execute on function public.release_user_reservation(uuid) to service_role;
grant execute on function public.reserve_user_usage(uuid, uuid, text)
  to service_role;
grant execute on function public.commit_user_reservation(uuid)
  to service_role;
grant execute on function public.get_user_usage(uuid) to service_role;

-- Supersede the historical Plus setting without editing applied migrations.
-- App-facing functions use the authenticated billing-account allowance above.
update public.usage_config set full_generation_allowance = 200 where tier = 'plus';
