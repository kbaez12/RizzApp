-- Phase 4B: server-side quota enforcement.
--
-- Tables + atomic reserve/commit/release RPCs. These tables hold ONLY
-- operational quota metadata (IDs, counters, timestamps, statuses).
-- No conversation text, screenshots, base64, generated replies, or photo
-- metadata is ever stored here.

-- ===================================================================
-- usage_config — single source of truth for allowances.
-- Changing an allowance later is an UPDATE here, not a code change.
-- ===================================================================
create table public.usage_config (
  tier text primary key check (tier in ('free', 'plus')),
  full_generation_allowance integer not null check (full_generation_allowance > 0),
  free_refinements_per_generation integer not null default 2
    check (free_refinements_per_generation >= 0),
  period_kind text not null check (period_kind in ('lifetime', 'monthly'))
);

-- Legitimate configuration (not test seed data):
--   FREE_FULL_ANALYSES = 5 (lifetime), PLUS_FULL_ANALYSES = 150 (monthly),
--   FREE_REFINEMENTS_PER_FULL_ANALYSIS = 2.
insert into public.usage_config
  (tier, full_generation_allowance, free_refinements_per_generation, period_kind)
values
  ('free', 5, 2, 'lifetime'),
  ('plus', 150, 2, 'monthly');

-- ===================================================================
-- installations — one row per anonymous installation.
-- Created lazily by the first /usage or /generate request.
-- ===================================================================
create table public.installations (
  installation_id uuid primary key,
  tier text not null default 'free' references public.usage_config (tier),
  analyses_used integer not null default 0 check (analyses_used >= 0),
  refinements_remaining integer not null default 0 check (refinements_remaining >= 0),
  -- Period anchor for monthly tiers. DEV PLACEHOLDER: RevenueCat entitlement
  -- becomes authoritative for Plus billing periods in a later phase. Do not
  -- treat installation-derived periods as production billing logic.
  period_start timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ===================================================================
-- usage_requests — reservations + idempotency ledger.
-- unique (installation_id, request_id) is the idempotency boundary:
-- a retried request can never charge twice, enforced by Postgres itself.
-- prev_* columns snapshot the exact pre-charge state so release can
-- restore it precisely (no heuristic reconstruction).
-- ===================================================================
create table public.usage_requests (
  reservation_id uuid primary key default gen_random_uuid(),
  installation_id uuid not null references public.installations (installation_id),
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
  -- Stale-reservation recovery: if the edge function crashes between
  -- reserve and commit/release, the reservation expires and is released
  -- opportunistically by the next reserve_usage call for the same
  -- installation (favoring refunds over charging users for crashes).
  -- Before Phase 5 production use, add a scheduled cleanup (pg_cron or a
  -- scheduled edge function) for installations that never return.
  expires_at timestamptz not null default now() + interval '2 minutes',
  unique (installation_id, request_id)
);

create index usage_requests_stale_idx
  on public.usage_requests (installation_id, status, expires_at);

-- ===================================================================
-- Lock down tables: server-only access.
-- RLS enabled with ZERO policies = anon/authenticated can touch nothing.
-- Grants revoked as a second layer. Only the service role (used by the
-- edge functions' admin client, which bypasses RLS) operates on these.
-- ===================================================================
alter table public.usage_config enable row level security;
alter table public.installations enable row level security;
alter table public.usage_requests enable row level security;

revoke all on table public.usage_config from public, anon, authenticated;
revoke all on table public.installations from public, anon, authenticated;
revoke all on table public.usage_requests from public, anon, authenticated;

-- ===================================================================
-- Functions. All SECURITY INVOKER (the service_role caller already has
-- full access; no need for SECURITY DEFINER / RLS bypass tricks), with
-- search_path pinned empty and fully qualified names.
-- EXECUTE is revoked from public/anon/authenticated below — the mobile
-- client can NEVER call these; only edge functions via service role.
-- ===================================================================

-- Wire-format usage snapshot: { remaining, limit, tier, refinements_remaining }
create function public.usage_status_for(p_installation public.installations)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'remaining', greatest(0, c.full_generation_allowance - p_installation.analyses_used),
    'limit', c.full_generation_allowance,
    'tier', p_installation.tier,
    'refinements_remaining', p_installation.refinements_remaining
  )
  from public.usage_config c
  where c.tier = p_installation.tier
$$;

-- DEV-ONLY monthly rollover for Plus test rows. RevenueCat will own real
-- billing periods later. Caller must hold the installation row lock.
create function public.refresh_period(p_installation_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.installations i
  set analyses_used = 0,
      refinements_remaining = 0,
      period_start = now(),
      updated_at = now()
  from public.usage_config c
  where i.installation_id = p_installation_id
    and c.tier = i.tier
    and c.period_kind = 'monthly'
    and now() >= i.period_start + interval '1 month';
end;
$$;

-- Releases one reservation, restoring the exact prior state.
-- free_refinement: inverse delta (+1, capped at the configured budget).
-- analysis: if no other charge interleaved (analyses_used is exactly
-- prev + 1), restore the full snapshot including the refinement budget;
-- otherwise apply only the inverse analysis delta and leave the
-- refinement counter, which now belongs to a newer generation.
create function public.release_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_res public.usage_requests;
  v_inst public.installations;
  v_cfg public.usage_config;
begin
  select * into v_res
  from public.usage_requests
  where reservation_id = p_reservation_id
  for update;

  if not found or v_res.status <> 'reserved' then
    select * into v_inst from public.installations
    where installation_id = v_res.installation_id;
    return jsonb_build_object(
      'outcome', 'noop',
      'usage', public.usage_status_for(v_inst)
    );
  end if;

  select * into v_inst
  from public.installations
  where installation_id = v_res.installation_id
  for update;

  select * into v_cfg from public.usage_config where tier = v_inst.tier;

  if v_res.charge_kind = 'free_refinement' then
    update public.installations
    set refinements_remaining =
          least(v_cfg.free_refinements_per_generation, refinements_remaining + 1),
        updated_at = now()
    where installation_id = v_inst.installation_id
    returning * into v_inst;
  else
    if v_inst.analyses_used = v_res.prev_analyses_used + 1 then
      update public.installations
      set analyses_used = v_res.prev_analyses_used,
          refinements_remaining = v_res.prev_refinements_remaining,
          updated_at = now()
      where installation_id = v_inst.installation_id
      returning * into v_inst;
    else
      update public.installations
      set analyses_used = greatest(0, analyses_used - 1),
          updated_at = now()
      where installation_id = v_inst.installation_id
      returning * into v_inst;
    end if;
  end if;

  update public.usage_requests
  set status = 'released', released_at = now()
  where reservation_id = p_reservation_id;

  return jsonb_build_object(
    'outcome', 'released',
    'usage', public.usage_status_for(v_inst)
  );
end;
$$;

-- Releases expired 'reserved' rows for one installation.
-- Caller must hold the installation row lock.
create function public.release_stale_reservations(p_installation_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_count integer := 0;
begin
  for v_id in
    select reservation_id
    from public.usage_requests
    where installation_id = p_installation_id
      and status = 'reserved'
      and expires_at < now()
  loop
    perform public.release_reservation(v_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Atomic quota reservation. THE quota decision point — edge functions do
-- no independent quota arithmetic. Concurrency-safe via the installation
-- row lock: two racing requests serialize here, so the last analysis can
-- only be reserved once and counters can never go negative (also enforced
-- by CHECK constraints).
--
-- Outcomes:
--   reserved       — charge applied; carries reservation_id + usage
--   duplicate      — (installation_id, request_id) seen before; NO new
--                    charge; carries prior status + current usage
--   quota_exceeded — no allowance for a required analysis; carries usage
create function public.reserve_usage(
  p_installation_id uuid,
  p_request_id uuid,
  p_action_kind text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_inst public.installations;
  v_cfg public.usage_config;
  v_existing public.usage_requests;
  v_charge text;
  v_reservation_id uuid;
begin
  if p_action_kind not in ('generation', 'refinement') then
    raise exception 'invalid action_kind %', p_action_kind;
  end if;

  -- Concurrency-safe lazy creation (two simultaneous first requests are fine).
  insert into public.installations (installation_id)
  values (p_installation_id)
  on conflict (installation_id) do nothing;

  -- Serialize all quota operations for this installation.
  select * into v_inst
  from public.installations
  where installation_id = p_installation_id
  for update;

  -- Idempotency: never charge the same logical request twice.
  select * into v_existing
  from public.usage_requests
  where installation_id = p_installation_id
    and request_id = p_request_id;
  if found then
    return jsonb_build_object(
      'outcome', 'duplicate',
      'reservation_id', v_existing.reservation_id,
      'prior_status', v_existing.status,
      'usage', public.usage_status_for(v_inst)
    );
  end if;

  -- Recover anything a crashed request left behind, then reload counters.
  perform public.release_stale_reservations(p_installation_id);
  perform public.refresh_period(p_installation_id);
  select * into v_inst
  from public.installations
  where installation_id = p_installation_id;

  select * into v_cfg from public.usage_config where tier = v_inst.tier;

  -- Server-side action classification decides the charge; free refinements
  -- first, then fall back to a full analysis (which resets the budget).
  if p_action_kind = 'refinement' and v_inst.refinements_remaining > 0 then
    v_charge := 'free_refinement';
  else
    v_charge := 'analysis';
  end if;

  if v_charge = 'analysis'
     and v_inst.analyses_used >= v_cfg.full_generation_allowance then
    return jsonb_build_object(
      'outcome', 'quota_exceeded',
      'usage', public.usage_status_for(v_inst)
    );
  end if;

  insert into public.usage_requests
    (installation_id, request_id, action_kind, charge_kind,
     prev_analyses_used, prev_refinements_remaining)
  values
    (p_installation_id, p_request_id, p_action_kind, v_charge,
     v_inst.analyses_used, v_inst.refinements_remaining)
  returning reservation_id into v_reservation_id;

  if v_charge = 'analysis' then
    update public.installations
    set analyses_used = analyses_used + 1,
        refinements_remaining = v_cfg.free_refinements_per_generation,
        updated_at = now()
    where installation_id = p_installation_id
    returning * into v_inst;
  else
    update public.installations
    set refinements_remaining = refinements_remaining - 1,
        updated_at = now()
    where installation_id = p_installation_id
    returning * into v_inst;
  end if;

  return jsonb_build_object(
    'outcome', 'reserved',
    'reservation_id', v_reservation_id,
    'usage', public.usage_status_for(v_inst)
  );
end;
$$;

-- Marks a reservation committed after successful work. If the reservation
-- was already released (e.g. stale cleanup won a race with a very slow
-- request), the charge stays refunded — we favor the user; rare and logged
-- by the caller.
create function public.commit_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_res public.usage_requests;
  v_inst public.installations;
begin
  update public.usage_requests
  set status = 'committed', committed_at = now()
  where reservation_id = p_reservation_id
    and status = 'reserved'
  returning * into v_res;

  if not found then
    select * into v_res from public.usage_requests
    where reservation_id = p_reservation_id;
  end if;

  select * into v_inst from public.installations
  where installation_id = v_res.installation_id;

  return jsonb_build_object(
    'outcome', case when v_res.status = 'committed' then 'committed' else 'not_reserved' end,
    'usage', public.usage_status_for(v_inst)
  );
end;
$$;

-- Authoritative usage for /usage. Creates the installation on first contact.
create function public.get_usage(p_installation_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_inst public.installations;
begin
  insert into public.installations (installation_id)
  values (p_installation_id)
  on conflict (installation_id) do nothing;

  select * into v_inst
  from public.installations
  where installation_id = p_installation_id
  for update;

  perform public.release_stale_reservations(p_installation_id);
  perform public.refresh_period(p_installation_id);

  select * into v_inst
  from public.installations
  where installation_id = p_installation_id;

  return public.usage_status_for(v_inst);
end;
$$;

-- ===================================================================
-- Function permissions: server-side only. Postgres grants EXECUTE to
-- PUBLIC by default — revoke explicitly, then grant only service_role.
-- The iOS client can never reach these RPCs (iOS → edge function →
-- privileged server call is the only path).
-- ===================================================================
revoke execute on function public.usage_status_for(public.installations) from public, anon, authenticated;
revoke execute on function public.refresh_period(uuid) from public, anon, authenticated;
revoke execute on function public.release_reservation(uuid) from public, anon, authenticated;
revoke execute on function public.release_stale_reservations(uuid) from public, anon, authenticated;
revoke execute on function public.reserve_usage(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.commit_reservation(uuid) from public, anon, authenticated;
revoke execute on function public.get_usage(uuid) from public, anon, authenticated;

grant execute on function public.usage_status_for(public.installations) to service_role;
grant execute on function public.refresh_period(uuid) to service_role;
grant execute on function public.release_reservation(uuid) to service_role;
grant execute on function public.release_stale_reservations(uuid) to service_role;
grant execute on function public.reserve_usage(uuid, uuid, text) to service_role;
grant execute on function public.commit_reservation(uuid) to service_role;
grant execute on function public.get_usage(uuid) to service_role;
