-- =====================================================================
-- robogold · Esquema inicial (v1, solo lectura para los usuarios)
-- Pegar entero en Supabase > SQL Editor > New query > Run
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PERFILES: uno por usuario registrado, se crea automáticamente
-- ---------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 2. CONECTORES: cada instalación del AddOn vinculada a un usuario.
--    Solo se guarda el hash del token, nunca el token en claro.
-- ---------------------------------------------------------------------
create table public.connectors (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  name         text not null default 'NinjaTrader',
  token_hash   text not null unique,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at   timestamptz
);

-- ---------------------------------------------------------------------
-- 3. CUENTAS de NinjaTrader de cada usuario
-- ---------------------------------------------------------------------
create table public.accounts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  nt_name      text not null,              -- nombre de la cuenta en NinjaTrader
  firm         text,                       -- prop firm (opcional)
  account_size numeric(14,2),              -- tamaño de la cuenta (opcional)
  created_at   timestamptz not null default now(),
  unique (user_id, nt_name)
);

-- ---------------------------------------------------------------------
-- 4. BOTS: se identifican por el prefijo de sus señales (p. ej. "DPV")
-- ---------------------------------------------------------------------
create table public.bots (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  tag          text not null,
  display_name text,
  created_at   timestamptz not null default now(),
  unique (user_id, tag)
);

-- ---------------------------------------------------------------------
-- 5. TRADES cerrados (operación completa: entrada + salida)
-- ---------------------------------------------------------------------
create table public.trades (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  account_id   uuid not null references public.accounts(id) on delete cascade,
  bot_id       uuid references public.bots(id) on delete set null,
  external_id  text not null,              -- id generado por el AddOn, evita duplicados
  instrument   text not null,
  direction    text not null check (direction in ('long', 'short')),
  quantity     integer not null check (quantity > 0),
  entry_time   timestamptz not null,
  exit_time    timestamptz not null,
  entry_price  numeric(14,4) not null,
  exit_price   numeric(14,4) not null,
  pnl          numeric(14,2) not null,     -- PnL bruto en $
  commission   numeric(14,2) not null default 0,
  mae          numeric(14,2),              -- máxima excursión adversa en $
  mfe          numeric(14,2),              -- máxima excursión favorable en $
  created_at   timestamptz not null default now(),
  unique (user_id, external_id)
);

create index trades_user_exit_idx on public.trades (user_id, exit_time desc);
create index trades_bot_exit_idx  on public.trades (bot_id, exit_time desc);
create index trades_acct_exit_idx on public.trades (account_id, exit_time desc);

-- ---------------------------------------------------------------------
-- 6. ESTADO EN VIVO: una fila por cuenta, se sobrescribe cada ~1 s
-- ---------------------------------------------------------------------
create table public.live_state (
  account_id         uuid primary key references public.accounts(id) on delete cascade,
  user_id            uuid not null references auth.users(id) on delete cascade,
  instrument         text,
  position           integer not null default 0,   -- + largo, - corto, 0 plano
  unrealized_pnl     numeric(14,2) not null default 0,
  realized_pnl_today numeric(14,2) not null default 0,
  cash_value         numeric(14,2),
  updated_at         timestamptz not null default now()
);

-- =====================================================================
-- SEGURIDAD (Row Level Security): cada usuario solo ve lo suyo.
-- Las escrituras de datos de trading las hará la Edge Function con la
-- clave secreta, así que los usuarios no tienen permiso de inserción.
-- =====================================================================
alter table public.profiles   enable row level security;
alter table public.connectors enable row level security;
alter table public.accounts   enable row level security;
alter table public.bots       enable row level security;
alter table public.trades     enable row level security;
alter table public.live_state enable row level security;

-- Perfiles
create policy "Ver mi perfil" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);
create policy "Editar mi perfil" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Conectores
create policy "Ver mis conectores" on public.connectors
  for select to authenticated using ((select auth.uid()) = user_id);

-- Cuentas (el usuario puede editar firma y tamaño)
create policy "Ver mis cuentas" on public.accounts
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Editar mis cuentas" on public.accounts
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Bots (el usuario puede ponerles un nombre visible)
create policy "Ver mis bots" on public.bots
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Editar mis bots" on public.bots
  for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Trades y estado en vivo: solo lectura
create policy "Ver mis trades" on public.trades
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Ver mi estado en vivo" on public.live_state
  for select to authenticated using ((select auth.uid()) = user_id);

-- =====================================================================
-- TIEMPO REAL: la web recibirá los cambios al instante
-- =====================================================================
alter publication supabase_realtime add table public.live_state, public.trades;
