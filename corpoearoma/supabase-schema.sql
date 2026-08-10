-- ═══════════════════════════════════════════════════════════════
-- CORPO & AROMA · Controle de estoque e finanças
-- Rode UMA VEZ no SQL Editor do Supabase (projeto novo OU o mesmo do fiado).
-- Não conflita com o fiado: todas as tabelas/funções usam prefixo ea_.
--
-- Login padrão criado abaixo:  usuário: corpoearoma   senha: aroma123
-- (troque a senha dentro do app, em Perfil)
-- ═══════════════════════════════════════════════════════════════
create extension if not exists pgcrypto with schema extensions;

-- ─── Tabelas ───────────────────────────────────────────
create table if not exists public.ea_usuarios (
  id uuid primary key default gen_random_uuid(),
  usuario text not null unique,
  senha_hash text not null,
  nome text not null default 'Corpo & Aroma',
  criado_em timestamptz not null default now()
);

create table if not exists public.ea_sessoes (
  token text primary key,
  usuario_id uuid references public.ea_usuarios(id) on delete cascade,
  expires_at timestamptz not null,
  criado_em timestamptz not null default now()
);

create table if not exists public.ea_produtos (
  id uuid primary key,
  usuario_id uuid not null references public.ea_usuarios(id) on delete cascade,
  nome text not null,
  categoria text not null default 'Outros',
  custo numeric(12,2) not null default 0,
  preco numeric(12,2) not null default 0,
  estoque numeric(12,2) not null default 0,
  estoque_min numeric(12,2) not null default 0,
  obs text default '',
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create index if not exists ea_produtos_usuario_idx on public.ea_produtos(usuario_id);

create table if not exists public.ea_movimentos (
  id uuid primary key,
  usuario_id uuid not null references public.ea_usuarios(id) on delete cascade,
  produto_id uuid,
  produto_nome text default '',
  tipo text not null check (tipo in ('entrada', 'saida', 'perda')),
  quantidade numeric(12,2) not null check (quantidade > 0),
  valor_unit numeric(12,2) not null default 0,
  custo_unit numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  nota text default '',
  data_ref date,
  ts timestamptz not null default now()
);

create index if not exists ea_movimentos_usuario_idx on public.ea_movimentos(usuario_id);
create index if not exists ea_movimentos_produto_idx on public.ea_movimentos(produto_id);

create table if not exists public.ea_despesas (
  id uuid primary key,
  usuario_id uuid not null references public.ea_usuarios(id) on delete cascade,
  descricao text not null,
  categoria text not null default 'Outros',
  valor numeric(12,2) not null check (valor > 0),
  data_ref date,
  ts timestamptz not null default now()
);

create index if not exists ea_despesas_usuario_idx on public.ea_despesas(usuario_id);

-- Conta padrão: corpoearoma / aroma123  (troque no app depois)
insert into public.ea_usuarios (usuario, senha_hash, nome)
values ('corpoearoma', crypt('aroma123', gen_salt('bf')), 'Corpo & Aroma')
on conflict (usuario) do nothing;

-- ─── Helpers ───────────────────────────────────────────
create or replace function public._ea_sessao_ok(p_token text)
returns ea_sessoes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s ea_sessoes;
begin
  select * into s from ea_sessoes where token = p_token and expires_at > now();
  if not found then
    raise exception 'Sessão inválida ou expirada';
  end if;
  return s;
end;
$$;

-- ─── Auth ──────────────────────────────────────────────
create or replace function public.ea_login(p_usuario text, p_senha text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  u ea_usuarios;
  tok text;
begin
  select * into u from ea_usuarios where lower(usuario) = lower(trim(coalesce(p_usuario, '')));
  if not found or u.senha_hash <> crypt(p_senha, u.senha_hash) then
    return json_build_object('ok', false, 'erro', 'Usuário ou senha incorretos.');
  end if;

  tok := encode(gen_random_bytes(24), 'hex');
  insert into ea_sessoes(token, usuario_id, expires_at)
  values (tok, u.id, now() + interval '60 days');

  return json_build_object(
    'ok', true,
    'token', tok,
    'usuario', u.usuario,
    'nome', u.nome
  );
end;
$$;

create or replace function public.ea_logout(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  delete from ea_sessoes where token = p_token;
  return json_build_object('ok', true);
end;
$$;

-- ─── Carregar tudo ─────────────────────────────────────
create or replace function public.ea_carregar(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s ea_sessoes;
  u ea_usuarios;
  prods json;
  movs json;
  deps json;
begin
  s := _ea_sessao_ok(p_token);
  select * into u from ea_usuarios where id = s.usuario_id;

  select coalesce(json_agg(json_build_object(
    'id', p.id,
    'nome', p.nome,
    'categoria', p.categoria,
    'custo', p.custo,
    'preco', p.preco,
    'estoque', p.estoque,
    'estoqueMin', p.estoque_min,
    'obs', p.obs,
    'ativo', p.ativo,
    'criadoEm', extract(epoch from p.criado_em) * 1000
  ) order by p.nome), '[]'::json)
  into prods
  from ea_produtos p
  where p.usuario_id = s.usuario_id;

  select coalesce(json_agg(json_build_object(
    'id', m.id,
    'produtoId', m.produto_id,
    'produtoNome', m.produto_nome,
    'tipo', m.tipo,
    'qtd', m.quantidade,
    'valorUnit', m.valor_unit,
    'custoUnit', m.custo_unit,
    'total', m.total,
    'nota', m.nota,
    'dataRef', m.data_ref,
    'ts', extract(epoch from m.ts) * 1000
  ) order by m.ts desc), '[]'::json)
  into movs
  from ea_movimentos m
  where m.usuario_id = s.usuario_id;

  select coalesce(json_agg(json_build_object(
    'id', d.id,
    'descricao', d.descricao,
    'categoria', d.categoria,
    'valor', d.valor,
    'dataRef', d.data_ref,
    'ts', extract(epoch from d.ts) * 1000
  ) order by d.ts desc), '[]'::json)
  into deps
  from ea_despesas d
  where d.usuario_id = s.usuario_id;

  return json_build_object(
    'ok', true,
    'usuario', u.usuario,
    'nome', u.nome,
    'produtos', prods,
    'movimentos', movs,
    'despesas', deps
  );
end;
$$;

-- ─── Salvar tudo (substitui os dados do usuário) ───────
create or replace function public.ea_salvar(p_token text, p_produtos json, p_movimentos json, p_despesas json)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s ea_sessoes;
  uid uuid;
  item json;
  pid uuid;
begin
  s := _ea_sessao_ok(p_token);
  uid := s.usuario_id;

  delete from ea_movimentos where usuario_id = uid;
  delete from ea_despesas where usuario_id = uid;
  delete from ea_produtos where usuario_id = uid;

  for item in select * from json_array_elements(coalesce(p_produtos, '[]'::json))
  loop
    pid := coalesce(nullif(item->>'id', '')::uuid, gen_random_uuid());
    insert into ea_produtos(id, usuario_id, nome, categoria, custo, preco, estoque, estoque_min, obs, ativo, criado_em)
    values (
      pid,
      uid,
      coalesce(nullif(trim(item->>'nome'), ''), 'Sem nome'),
      coalesce(nullif(trim(item->>'categoria'), ''), 'Outros'),
      coalesce(nullif(item->>'custo', '')::numeric, 0),
      coalesce(nullif(item->>'preco', '')::numeric, 0),
      coalesce(nullif(item->>'estoque', '')::numeric, 0),
      coalesce(nullif(item->>'estoqueMin', '')::numeric, 0),
      coalesce(item->>'obs', ''),
      coalesce((item->>'ativo')::boolean, true),
      case
        when item->>'criadoEm' is not null and item->>'criadoEm' <> ''
          then to_timestamp((item->>'criadoEm')::double precision / 1000.0)
        else now()
      end
    );
  end loop;

  for item in select * from json_array_elements(coalesce(p_movimentos, '[]'::json))
  loop
    insert into ea_movimentos(id, usuario_id, produto_id, produto_nome, tipo, quantidade, valor_unit, custo_unit, total, nota, data_ref, ts)
    values (
      coalesce(nullif(item->>'id', '')::uuid, gen_random_uuid()),
      uid,
      nullif(item->>'produtoId', '')::uuid,
      coalesce(item->>'produtoNome', ''),
      item->>'tipo',
      (item->>'qtd')::numeric,
      coalesce(nullif(item->>'valorUnit', '')::numeric, 0),
      coalesce(nullif(item->>'custoUnit', '')::numeric, 0),
      coalesce(nullif(item->>'total', '')::numeric, 0),
      coalesce(item->>'nota', ''),
      nullif(item->>'dataRef', '')::date,
      case
        when item->>'ts' is not null and item->>'ts' <> ''
          then to_timestamp((item->>'ts')::double precision / 1000.0)
        else now()
      end
    );
  end loop;

  for item in select * from json_array_elements(coalesce(p_despesas, '[]'::json))
  loop
    insert into ea_despesas(id, usuario_id, descricao, categoria, valor, data_ref, ts)
    values (
      coalesce(nullif(item->>'id', '')::uuid, gen_random_uuid()),
      uid,
      coalesce(nullif(trim(item->>'descricao'), ''), 'Despesa'),
      coalesce(nullif(trim(item->>'categoria'), ''), 'Outros'),
      (item->>'valor')::numeric,
      nullif(item->>'dataRef', '')::date,
      case
        when item->>'ts' is not null and item->>'ts' <> ''
          then to_timestamp((item->>'ts')::double precision / 1000.0)
        else now()
      end
    );
  end loop;

  return json_build_object('ok', true);
end;
$$;

-- ─── Perfil (nome da loja / senha) ─────────────────────
create or replace function public.ea_atualizar_perfil(
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
  s ea_sessoes;
  u ea_usuarios;
begin
  s := _ea_sessao_ok(p_token);
  select * into u from ea_usuarios where id = s.usuario_id;
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
    update ea_usuarios set senha_hash = crypt(trim(p_senha_nova), gen_salt('bf')) where id = u.id;
  end if;

  if p_nome is not null and trim(p_nome) <> '' then
    update ea_usuarios set nome = trim(p_nome) where id = u.id;
    u.nome := trim(p_nome);
  end if;

  return json_build_object('ok', true, 'nome', u.nome);
end;
$$;

-- ─── Permissões ────────────────────────────────────────
grant usage on schema public to anon, authenticated;
grant execute on function public.ea_login(text, text) to anon, authenticated;
grant execute on function public.ea_logout(text) to anon, authenticated;
grant execute on function public.ea_carregar(text) to anon, authenticated;
grant execute on function public.ea_salvar(text, json, json, json) to anon, authenticated;
grant execute on function public.ea_atualizar_perfil(text, text, text, text) to anon, authenticated;

alter table public.ea_usuarios enable row level security;
alter table public.ea_sessoes enable row level security;
alter table public.ea_produtos enable row level security;
alter table public.ea_movimentos enable row level security;
alter table public.ea_despesas enable row level security;

revoke execute on function public._ea_sessao_ok(text) from public, anon, authenticated;

-- Sem policies = ninguém acessa as tabelas direto; só via RPCs acima.
