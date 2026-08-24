-- Patch: freio de força bruta no login + backup completo (admin)
-- Rode DEPOIS de supabase-schema.sql e patch-lixeira.sql.
-- Efeito nos clientes: nenhum. Só quem errar a senha 5x seguidas espera 15 min.

-- ─── 1) Rate limit de login ────────────────────────────
create table if not exists public.login_tentativas (
  usuario text primary key,
  falhas int not null default 0,
  bloqueado_ate timestamptz
);

-- Ninguém lê/escreve direto; só as funções security definer tocam.
alter table public.login_tentativas enable row level security;
revoke all on public.login_tentativas from anon, authenticated;

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
  b timestamptz;
  f int;
begin
  -- 5 erros seguidos = 15 min de bloqueio para esse usuário
  select bloqueado_ate into b from login_tentativas where usuario = u;
  if b is not null and b > now() then
    return json_build_object(
      'ok', false,
      'erro', 'Muitas tentativas erradas. Tente de novo em ' ||
              greatest(1, ceil(extract(epoch from (b - now())) / 60)::int) || ' min.'
    );
  end if;

  select * into a from admin_conta where id = 1;
  if lower(a.usuario) = u and a.senha_hash = crypt(p_senha, a.senha_hash) then
    delete from login_tentativas where usuario = u;
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
    insert into login_tentativas (usuario, falhas) values (u, 1)
    on conflict (usuario) do update set falhas = login_tentativas.falhas + 1
    returning falhas into f;
    if f >= 5 then
      update login_tentativas
      set bloqueado_ate = now() + interval '15 minutes', falhas = 0
      where usuario = u;
    end if;
    return json_build_object('ok', false, 'erro', 'Usuário ou senha incorretos.');
  end if;
  if m.bloqueado then
    return json_build_object('ok', false, 'erro', 'Mercado bloqueado.');
  end if;

  if m.trial_inicio is null then
    update mercados set trial_inicio = now() where id = m.id;
    m.trial_inicio := now();
  end if;

  delete from login_tentativas where usuario = u;
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

-- ─── 2) Backup completo (só admin) ─────────────────────
-- Usado pelo script fiado/backup/fiado-backup.ps1 (backup diário local + e-mail).
-- Não expõe senha_hash de ninguém.
create or replace function public.fiado_admin_backup(p_token text)
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

  return json_build_object(
    'ok', true,
    'geradoEm', now(),
    'mercados', coalesce((select json_agg(row_to_json(t)) from (
      select id, usuario, nome, trial_inicio, pago, bloqueado, valor_licenca, chave_pix, criado_em
      from mercados order by criado_em
    ) t), '[]'::json),
    'clientes', coalesce((select json_agg(row_to_json(t)) from (
      select * from clientes order by criado_em
    ) t), '[]'::json),
    'movimentos', coalesce((select json_agg(row_to_json(t)) from (
      select * from movimentos order by ts
    ) t), '[]'::json),
    'diario', coalesce((select json_agg(row_to_json(t)) from (
      select * from diario_eventos order by ts
    ) t), '[]'::json),
    'lixeira', coalesce((select json_agg(row_to_json(t)) from (
      select * from movimentos_lixeira order by apagado_em
    ) t), '[]'::json)
  );
end;
$$;

grant execute on function public.fiado_admin_backup(text) to anon, authenticated;
