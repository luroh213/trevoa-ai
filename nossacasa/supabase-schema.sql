-- ═══════════════════════════════════════════════════════════════
-- NOSSA CASA · Finanças do casal + despensa + gatos
-- Rode UMA VEZ no SQL Editor do Supabase (pode ser o MESMO projeto
-- do fiado/corpoearoma — nada conflita, tudo usa prefixo nc_).
--
-- Login padrão criado abaixo:  usuário: casa   senha: casa123
-- (troque a senha dentro do app, em Ajustes)
-- ═══════════════════════════════════════════════════════════════
create extension if not exists pgcrypto with schema extensions;

-- ─── Tabelas ───────────────────────────────────────────
create table if not exists public.nc_usuarios (
  id uuid primary key default gen_random_uuid(),
  usuario text not null unique,
  senha_hash text not null,
  nome text not null default 'Nossa Casa',
  criado_em timestamptz not null default now()
);

create table if not exists public.nc_sessoes (
  token text primary key,
  usuario_id uuid references public.nc_usuarios(id) on delete cascade,
  expires_at timestamptz not null,
  criado_em timestamptz not null default now()
);

-- Um documento JSON por conta: estado inteiro do app.
-- App pequeno, 2 pessoas — doc único é mais simples e robusto
-- do que sincronizar 8 tabelas entre dois celulares.
create table if not exists public.nc_state (
  usuario_id uuid primary key references public.nc_usuarios(id) on delete cascade,
  doc jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);

-- Conta padrão: casa / casa123  (troque no app depois)
insert into public.nc_usuarios (usuario, senha_hash, nome)
values ('casa', crypt('casa123', gen_salt('bf')), 'Nossa Casa')
on conflict (usuario) do nothing;

-- ─── Helpers ───────────────────────────────────────────
create or replace function public._nc_sessao_ok(p_token text)
returns nc_sessoes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s nc_sessoes;
begin
  select * into s from nc_sessoes where token = p_token and expires_at > now();
  if not found then
    raise exception 'Sessão inválida ou expirada';
  end if;
  return s;
end;
$$;

-- ─── Auth ──────────────────────────────────────────────
create or replace function public.nc_login(p_usuario text, p_senha text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  u nc_usuarios;
  tok text;
begin
  select * into u from nc_usuarios where lower(usuario) = lower(trim(coalesce(p_usuario, '')));
  if not found or u.senha_hash <> crypt(p_senha, u.senha_hash) then
    return json_build_object('ok', false, 'erro', 'Usuário ou senha incorretos.');
  end if;

  tok := encode(gen_random_bytes(24), 'hex');
  insert into nc_sessoes(token, usuario_id, expires_at)
  values (tok, u.id, now() + interval '60 days');

  return json_build_object(
    'ok', true,
    'token', tok,
    'usuario', u.usuario,
    'nome', u.nome
  );
end;
$$;

create or replace function public.nc_logout(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  delete from nc_sessoes where token = p_token;
  return json_build_object('ok', true);
end;
$$;

-- ─── Carregar estado ───────────────────────────────────
create or replace function public.nc_carregar(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s nc_sessoes;
  u nc_usuarios;
  st nc_state;
begin
  s := _nc_sessao_ok(p_token);
  select * into u from nc_usuarios where id = s.usuario_id;
  select * into st from nc_state where usuario_id = s.usuario_id;

  return json_build_object(
    'ok', true,
    'usuario', u.usuario,
    'nome', u.nome,
    'doc', coalesce(st.doc, '{}'::jsonb),
    'atualizadoEm', coalesce(extract(epoch from st.atualizado_em) * 1000, 0)
  );
end;
$$;

-- ─── Salvar estado (doc inteiro, último que escreve ganha) ──
create or replace function public.nc_salvar(p_token text, p_doc json)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s nc_sessoes;
begin
  s := _nc_sessao_ok(p_token);

  insert into nc_state (usuario_id, doc, atualizado_em)
  values (s.usuario_id, coalesce(p_doc::jsonb, '{}'::jsonb), now())
  on conflict (usuario_id)
  do update set doc = excluded.doc, atualizado_em = now();

  return json_build_object(
    'ok', true,
    'atualizadoEm', extract(epoch from now()) * 1000
  );
end;
$$;

-- ─── Perfil (nome da casa / senha) ─────────────────────
create or replace function public.nc_atualizar_perfil(
  p_token text,
  p_nome text default null,
  p_senha_atual text default null,
  p_senha_nova text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s nc_sessoes;
  u nc_usuarios;
begin
  s := _nc_sessao_ok(p_token);
  select * into u from nc_usuarios where id = s.usuario_id;
  if not found then
    raise exception 'Usuário não encontrado';
  end if;

  if p_senha_nova is not null and trim(p_senha_nova) <> '' then
    if length(trim(p_senha_nova)) < 4 then
      return json_build_object('ok', false, 'erro', 'Nova senha muito curta (mín. 4).');
    end if;
    if u.senha_hash <> crypt(coalesce(p_senha_atual, ''), u.senha_hash) then
      return json_build_object('ok', false, 'erro', 'Senha atual incorreta.');
    end if;
    update nc_usuarios set senha_hash = crypt(trim(p_senha_nova), gen_salt('bf')) where id = u.id;
  end if;

  if p_nome is not null and trim(p_nome) <> '' then
    update nc_usuarios set nome = trim(p_nome) where id = u.id;
    u.nome := trim(p_nome);
  end if;

  return json_build_object('ok', true, 'nome', u.nome);
end;
$$;

-- ─── Permissões ────────────────────────────────────────
grant usage on schema public to anon, authenticated;
grant execute on function public.nc_login(text, text) to anon, authenticated;
grant execute on function public.nc_logout(text) to anon, authenticated;
grant execute on function public.nc_carregar(text) to anon, authenticated;
grant execute on function public.nc_salvar(text, json) to anon, authenticated;
grant execute on function public.nc_atualizar_perfil(text, text, text, text) to anon, authenticated;

alter table public.nc_usuarios enable row level security;
alter table public.nc_sessoes enable row level security;
alter table public.nc_state enable row level security;

revoke execute on function public._nc_sessao_ok(text) from public, anon, authenticated;

-- Sem policies = ninguém acessa as tabelas direto; só via RPCs acima.
