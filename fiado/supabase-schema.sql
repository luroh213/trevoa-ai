-- Fiado na nuvem — rode no SQL Editor do Supabase (uma vez)
-- Extensões
create extension if not exists pgcrypto with schema extensions;

-- ─── Tabelas ───────────────────────────────────────────
create table if not exists public.mercados (
  id uuid primary key default gen_random_uuid(),
  usuario text not null unique,
  senha_hash text not null,
  nome text not null default 'Fiado',
  trial_inicio timestamptz,
  pago boolean not null default false,
  bloqueado boolean not null default false,
  valor_licenca numeric(12,2) default 97,
  chave_pix text default '',
  criado_em timestamptz not null default now()
);

create table if not exists public.sessoes (
  token text primary key,
  mercado_id uuid references public.mercados(id) on delete cascade,
  role text not null check (role in ('user', 'admin')),
  acting_mercado_id uuid references public.mercados(id) on delete set null,
  expires_at timestamptz not null,
  criado_em timestamptz not null default now()
);

create table if not exists public.clientes (
  id uuid primary key,
  mercado_id uuid not null references public.mercados(id) on delete cascade,
  nome text not null,
  fone text default '',
  obs text default '',
  limite numeric(12,2),
  criado_em timestamptz not null default now()
);

create index if not exists clientes_mercado_idx on public.clientes(mercado_id);

create table if not exists public.movimentos (
  id uuid primary key,
  mercado_id uuid not null references public.mercados(id) on delete cascade,
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  tipo text not null check (tipo in ('debito', 'pagamento')),
  valor numeric(12,2) not null check (valor > 0),
  nota text default '',
  data_ref date,
  forma text,
  ts timestamptz not null default now()
);

create index if not exists movimentos_cliente_idx on public.movimentos(cliente_id);
create index if not exists movimentos_mercado_idx on public.movimentos(mercado_id);

create table if not exists public.diario_eventos (
  id uuid primary key,
  mercado_id uuid not null references public.mercados(id) on delete cascade,
  texto text not null,
  ts bigint not null,
  criado_em timestamptz not null default now()
);

create index if not exists diario_mercado_ts_idx on public.diario_eventos(mercado_id, ts desc);

create table if not exists public.admin_conta (
  id int primary key default 1 check (id = 1),
  usuario text not null default 'admin',
  senha_hash text not null,
  seu_whatsapp text default '',
  codigo_liberacao text default 'LIBERA-MERCADO-26',
  trial_dias int default 14
);

-- Admin padrão: admin / admin123  (troque depois)
insert into public.admin_conta (id, usuario, senha_hash)
values (1, 'admin', crypt('admin123', gen_salt('bf')))
on conflict (id) do nothing;

-- Mercado demo (opcional): mercado / fiado123
insert into public.mercados (usuario, senha_hash, nome, trial_inicio)
values ('mercado', crypt('fiado123', gen_salt('bf')), 'Fiado', now())
on conflict (usuario) do nothing;

-- ─── Helpers ───────────────────────────────────────────
create or replace function public._nova_sessao(
  p_role text,
  p_mercado_id uuid,
  p_acting uuid default null
) returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t text := encode(gen_random_bytes(24), 'hex');
begin
  insert into sessoes(token, mercado_id, role, acting_mercado_id, expires_at)
  values (t, p_mercado_id, p_role, p_acting, now() + interval '30 days');
  return t;
end;
$$;

create or replace function public._sessao_ok(p_token text)
returns sessoes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
begin
  select * into s from sessoes where token = p_token and expires_at > now();
  if not found then
    raise exception 'Sessão inválida ou expirada';
  end if;
  return s;
end;
$$;

create or replace function public._mercado_ativo(p_sess sessoes)
returns uuid
language plpgsql
stable
set search_path = public, extensions
as $$
begin
  if p_sess.role = 'admin' and p_sess.acting_mercado_id is not null then
    return p_sess.acting_mercado_id;
  end if;
  return p_sess.mercado_id;
end;
$$;

-- ─── Auth ──────────────────────────────────────────────
create or replace function public.fiado_login(p_usuario text, p_senha text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  a admin_conta;
  m mercados;
  tok text;
  u text := lower(trim(coalesce(p_usuario, '')));
begin
  select * into a from admin_conta where id = 1;
  if lower(a.usuario) = u and a.senha_hash = crypt(p_senha, a.senha_hash) then
    tok := _nova_sessao('admin', null, null);
    return json_build_object(
      'ok', true,
      'role', 'admin',
      'token', tok,
      'usuario', a.usuario,
      'nome', 'Administrador',
      'trialDias', a.trial_dias,
      'codigoLiberacao', a.codigo_liberacao,
      'seuWhatsapp', a.seu_whatsapp
    );
  end if;

  select * into m from mercados where lower(usuario) = u;
  if not found or m.senha_hash <> crypt(p_senha, m.senha_hash) then
    return json_build_object('ok', false, 'erro', 'Usuário ou senha incorretos.');
  end if;
  if m.bloqueado then
    return json_build_object('ok', false, 'erro', 'Mercado bloqueado.');
  end if;

  if m.trial_inicio is null then
    update mercados set trial_inicio = now() where id = m.id;
    m.trial_inicio := now();
  end if;

  tok := _nova_sessao('user', m.id, null);
  return json_build_object(
    'ok', true,
    'role', 'user',
    'token', tok,
    'usuario', m.usuario,
    'mercadoId', m.id,
    'nome', m.nome,
    'pago', m.pago,
    'bloqueado', m.bloqueado,
    'trialInicio', m.trial_inicio,
    'valorLicenca', m.valor_licenca,
    'chavePix', m.chave_pix,
    'trialDias', a.trial_dias,
    'codigoLiberacao', a.codigo_liberacao,
    'seuWhatsapp', a.seu_whatsapp
  );
end;
$$;

create or replace function public.fiado_logout(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  delete from sessoes where token = p_token;
  return json_build_object('ok', true);
end;
$$;

-- ─── Caderno ───────────────────────────────────────────
create or replace function public.fiado_carregar_caderno(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  result json;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    raise exception 'Selecione um mercado';
  end if;

  select coalesce(json_agg(row_to_json(x) order by x.nome), '[]'::json)
  into result
  from (
    select
      c.id,
      c.nome,
      c.fone,
      c.obs,
      c.limite,
      extract(epoch from c.criado_em) * 1000 as "criadoEm",
      coalesce((
        select json_agg(json_build_object(
          'id', mv.id,
          'tipo', mv.tipo,
          'valor', mv.valor,
          'nota', mv.nota,
          'dataRef', mv.data_ref,
          'forma', mv.forma,
          'ts', extract(epoch from mv.ts) * 1000
        ) order by mv.ts desc)
        from movimentos mv where mv.cliente_id = c.id
      ), '[]'::json) as movs
    from clientes c
    where c.mercado_id = mid
  ) x;

  return json_build_object('ok', true, 'clientes', result, 'mercadoId', mid);
end;
$$;

create or replace function public.fiado_salvar_caderno(p_token text, p_clientes json)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  cli json;
  mov json;
  cid uuid;
  mid_mov uuid;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    raise exception 'Selecione um mercado';
  end if;

  -- Substitui o caderno inteiro (simples e confiável pro app atual)
  delete from movimentos where mercado_id = mid;
  delete from clientes where mercado_id = mid;

  for cli in select * from json_array_elements(p_clientes)
  loop
    cid := coalesce((cli->>'id')::uuid, gen_random_uuid());
    insert into clientes(id, mercado_id, nome, fone, obs, limite, criado_em)
    values (
      cid,
      mid,
      coalesce(cli->>'nome', 'Sem nome'),
      coalesce(cli->>'fone', ''),
      coalesce(cli->>'obs', ''),
      nullif(cli->>'limite', '')::numeric,
      case
        when cli->>'criadoEm' is not null and cli->>'criadoEm' <> ''
          then to_timestamp((cli->>'criadoEm')::double precision / 1000.0)
        else now()
      end
    );

    if cli->'movs' is not null and json_typeof(cli->'movs') = 'array' then
      for mov in select * from json_array_elements(cli->'movs')
      loop
        mid_mov := coalesce((mov->>'id')::uuid, gen_random_uuid());
        insert into movimentos(id, mercado_id, cliente_id, tipo, valor, nota, data_ref, forma, ts)
        values (
          mid_mov,
          mid,
          cid,
          mov->>'tipo',
          (mov->>'valor')::numeric,
          coalesce(mov->>'nota', ''),
          nullif(mov->>'dataRef', '')::date,
          nullif(mov->>'forma', ''),
          case
            when mov->>'ts' is not null and mov->>'ts' <> ''
              then to_timestamp((mov->>'ts')::double precision / 1000.0)
            else now()
          end
        );
      end loop;
    end if;
  end loop;

  return json_build_object('ok', true, 'qtd', json_array_length(p_clientes));
end;
$$;

-- ─── Diário do balcão ──────────────────────────────────
create or replace function public.fiado_registrar_diario(
  p_token text,
  p_id uuid,
  p_texto text,
  p_ts bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    return json_build_object('ok', false, 'erro', 'Mercado não definido');
  end if;
  if p_id is null or coalesce(trim(p_texto), '') = '' then
    return json_build_object('ok', false, 'erro', 'Dados inválidos');
  end if;

  insert into diario_eventos(id, mercado_id, texto, ts)
  values (p_id, mid, trim(p_texto), coalesce(p_ts, (extract(epoch from now()) * 1000)::bigint))
  on conflict (id) do nothing;

  delete from diario_eventos d
  where d.mercado_id = mid
    and d.id not in (
      select id from diario_eventos
      where mercado_id = mid
      order by ts desc
      limit 500
    );

  return json_build_object('ok', true);
end;
$$;

create or replace function public.fiado_listar_diario(
  p_token text,
  p_limite int default 120
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  lim int := greatest(1, least(coalesce(p_limite, 120), 500));
  result json;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    return json_build_object('ok', false, 'erro', 'Mercado não definido');
  end if;

  select coalesce(json_agg(row_to_json(t) order by t.ts desc), '[]'::json)
  into result
  from (
    select d.id, d.texto, d.ts
    from diario_eventos d
    where d.mercado_id = mid
    order by d.ts desc
    limit lim
  ) t;

  return json_build_object('ok', true, 'eventos', result);
end;
$$;

-- ─── Admin mercados ────────────────────────────────────
create or replace function public.fiado_admin_listar_mercados(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  result json;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só admin';
  end if;

  select coalesce(json_agg(json_build_object(
    'id', m.id,
    'usuario', m.usuario,
    'nome', m.nome,
    'pago', m.pago,
    'bloqueado', m.bloqueado,
    'trialInicio', m.trial_inicio,
    'valorLicenca', m.valor_licenca,
    'chavePix', m.chave_pix,
    'clientes', (select count(*) from clientes c where c.mercado_id = m.id)
  ) order by m.criado_em desc), '[]'::json)
  into result
  from mercados m;

  return json_build_object('ok', true, 'mercados', result);
end;
$$;

create or replace function public.fiado_admin_criar_mercado(
  p_token text,
  p_usuario text,
  p_senha text,
  p_nome text default 'Fiado'
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  u text := lower(trim(coalesce(p_usuario, '')));
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só admin';
  end if;
  if length(u) < 2 or length(p_senha) < 4 then
    raise exception 'Usuário/senha inválidos';
  end if;
  if exists (select 1 from mercados where lower(usuario) = u) then
    return json_build_object('ok', false, 'erro', 'Já existe um mercado com esse usuário.');
  end if;

  insert into mercados(usuario, senha_hash, nome, trial_inicio)
  values (u, crypt(p_senha, gen_salt('bf')), coalesce(nullif(trim(p_nome), ''), 'Fiado'), now())
  returning id into mid;

  return json_build_object('ok', true, 'id', mid, 'usuario', u);
exception
  when unique_violation then
    return json_build_object('ok', false, 'erro', 'Já existe um mercado com esse usuário.');
end;
$$;

create or replace function public.fiado_admin_abrir_mercado(p_token text, p_mercado_id uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  m mercados;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só admin';
  end if;
  select * into m from mercados where id = p_mercado_id;
  if not found then
    raise exception 'Mercado não encontrado';
  end if;
  update sessoes set acting_mercado_id = p_mercado_id where token = p_token;
  return json_build_object(
    'ok', true,
    'mercadoId', m.id,
    'usuario', m.usuario,
    'nome', m.nome,
    'pago', m.pago,
    'bloqueado', m.bloqueado,
    'trialInicio', m.trial_inicio,
    'valorLicenca', m.valor_licenca,
    'chavePix', m.chave_pix
  );
end;
$$;

create or replace function public.fiado_admin_atualizar_mercado(
  p_token text,
  p_mercado_id uuid,
  p_nome text default null,
  p_senha text default null,
  p_pago boolean default null,
  p_bloqueado boolean default null,
  p_valor numeric default null,
  p_pix text default null,
  p_reiniciar_trial boolean default false
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só admin';
  end if;

  update mercados set
    nome = coalesce(nullif(trim(p_nome), ''), nome),
    senha_hash = case when p_senha is not null and length(p_senha) >= 4
      then crypt(p_senha, gen_salt('bf')) else senha_hash end,
    pago = coalesce(p_pago, pago),
    bloqueado = coalesce(p_bloqueado, bloqueado),
    valor_licenca = coalesce(p_valor, valor_licenca),
    chave_pix = coalesce(p_pix, chave_pix),
    trial_inicio = case when p_reiniciar_trial then now() else trial_inicio end
  where id = p_mercado_id;

  return json_build_object('ok', true);
end;
$$;

create or replace function public.fiado_admin_trocar_senha(p_token text, p_atual text, p_nova text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  a admin_conta;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só admin';
  end if;
  select * into a from admin_conta where id = 1;
  if a.senha_hash <> crypt(p_atual, a.senha_hash) then
    return json_build_object('ok', false, 'erro', 'Senha atual incorreta.');
  end if;
  if length(p_nova) < 4 then
    return json_build_object('ok', false, 'erro', 'Nova senha muito curta.');
  end if;
  update admin_conta set senha_hash = crypt(p_nova, gen_salt('bf')) where id = 1;
  return json_build_object('ok', true);
end;
$$;

create or replace function public.fiado_liberar_com_codigo(p_token text, p_codigo text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  a admin_conta;
  mid uuid;
begin
  s := _sessao_ok(p_token);
  select * into a from admin_conta where id = 1;
  if coalesce(nullif(trim(p_codigo), ''), '') <> coalesce(a.codigo_liberacao, '') then
    return json_build_object('ok', false, 'erro', 'Código inválido');
  end if;
  mid := _mercado_ativo(s);
  if mid is null then
    return json_build_object('ok', false, 'erro', 'Mercado não identificado');
  end if;
  update mercados set pago = true, bloqueado = false where id = mid;
  return json_build_object('ok', true);
end;
$$;

create or replace function public.fiado_mercado_info(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  m mercados;
  a admin_conta;
begin
  s := _sessao_ok(p_token);
  select * into a from admin_conta where id = 1;
  mid := _mercado_ativo(s);
  if mid is null then
    return json_build_object(
      'ok', true,
      'role', s.role,
      'trialDias', a.trial_dias,
      'codigoLiberacao', a.codigo_liberacao,
      'seuWhatsapp', a.seu_whatsapp
    );
  end if;
  select * into m from mercados where id = mid;
  return json_build_object(
    'ok', true,
    'role', s.role,
    'mercadoId', m.id,
    'usuario', m.usuario,
    'nome', m.nome,
    'pago', m.pago,
    'bloqueado', m.bloqueado,
    'trialInicio', m.trial_inicio,
    'valorLicenca', m.valor_licenca,
    'chavePix', m.chave_pix,
    'trialDias', a.trial_dias,
    'codigoLiberacao', a.codigo_liberacao,
    'seuWhatsapp', a.seu_whatsapp
  );
end;
$$;

-- ─── Perfil do próprio mercado (nome da loja / senha) ──
create or replace function public.fiado_mercado_atualizar_perfil(
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
  s sessoes;
  m mercados;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'user' then
    raise exception 'Só o próprio mercado';
  end if;
  select * into m from mercados where id = s.mercado_id;
  if not found then
    raise exception 'Mercado não encontrado';
  end if;

  if p_senha_nova is not null and trim(p_senha_nova) <> '' then
    if length(trim(p_senha_nova)) < 4 then
      return json_build_object('ok', false, 'erro', 'Nova senha muito curta (mín. 4).');
    end if;
    if m.senha_hash <> crypt(coalesce(p_senha_atual, ''), m.senha_hash) then
      return json_build_object('ok', false, 'erro', 'Senha atual incorreta.');
    end if;
    update mercados set senha_hash = crypt(trim(p_senha_nova), gen_salt('bf')) where id = m.id;
  end if;

  if p_nome is not null and trim(p_nome) <> '' then
    update mercados set nome = trim(p_nome) where id = m.id;
    m.nome := trim(p_nome);
  end if;

  return json_build_object('ok', true, 'nome', m.nome);
end;
$$;

-- Libera chamadas do anon key (app web)
grant usage on schema public to anon, authenticated;
grant execute on function public.fiado_login(text, text) to anon, authenticated;
grant execute on function public.fiado_logout(text) to anon, authenticated;
grant execute on function public.fiado_carregar_caderno(text) to anon, authenticated;
grant execute on function public.fiado_salvar_caderno(text, json) to anon, authenticated;
grant execute on function public.fiado_admin_listar_mercados(text) to anon, authenticated;
grant execute on function public.fiado_admin_criar_mercado(text, text, text, text) to anon, authenticated;
grant execute on function public.fiado_admin_abrir_mercado(text, uuid) to anon, authenticated;
grant execute on function public.fiado_admin_atualizar_mercado(text, uuid, text, text, boolean, boolean, numeric, text, boolean) to anon, authenticated;
grant execute on function public.fiado_admin_trocar_senha(text, text, text) to anon, authenticated;
grant execute on function public.fiado_liberar_com_codigo(text, text) to anon, authenticated;
grant execute on function public.fiado_mercado_info(text) to anon, authenticated;
grant execute on function public.fiado_mercado_atualizar_perfil(text, text, text, text) to anon, authenticated;
grant execute on function public.fiado_registrar_diario(text, uuid, text, bigint) to anon, authenticated;
grant execute on function public.fiado_listar_diario(text, int) to anon, authenticated;

-- Bloqueia acesso direto às tabelas pelo anon
alter table public.mercados enable row level security;
alter table public.sessoes enable row level security;
alter table public.clientes enable row level security;
alter table public.movimentos enable row level security;
alter table public.diario_eventos enable row level security;
alter table public.admin_conta enable row level security;

-- Helpers internos: só as funções acima chamam; fecha acesso externo
revoke execute on function public._nova_sessao(text, uuid, uuid) from public, anon, authenticated;
revoke execute on function public._sessao_ok(text) from public, anon, authenticated;

-- Sem policies = ninguém acessa direto; só via SECURITY DEFINER RPCs
