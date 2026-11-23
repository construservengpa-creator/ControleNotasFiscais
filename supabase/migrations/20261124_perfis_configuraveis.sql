-- Perfis configuráveis.
--
-- Cada usuário passa a ter um PERFIL (tabela perfis). O perfil tem:
--   * nível base (admin / supervisor / operador) — define o que o usuário enxerga e as regras de coluna,
--     exatamente como o antigo "papel" (profiles.role continua existindo e é preenchido a partir do perfil,
--     então todas as regras atuais do banco seguem funcionando);
--   * permissões liga/desliga (perfis.permissoes) — só valem as que existem para o nível
--     (permissoes_do_nivel); o nível Administrador tem todas, sempre;
--   * descrição da rotina do perfil (perfis.descricao) — o que esse perfil faz no dia a dia.
--
-- Os três perfis atuais viram perfis "de sistema" com as permissões que já tinham: nada muda para
-- ninguém até o administrador editar um perfil ou criar um novo.

-- 1) Catálogo de permissões por nível ---------------------------------------------------------------
create or replace function public.permissoes_do_nivel(p_nivel text)
 returns text[]
 language sql
 immutable
as $$
  select case p_nivel
    when 'supervisor' then array['cadastrar_nota', 'editar_card', 'concluir_card', 'mover_cards', 'distribuir_cards',
                                 'alterar_prioridade', 'validar_lancamento', 'excluir_anexos', 'importar',
                                 'gerenciar_obras', 'ver_auditoria', 'ver_usuarios']
    when 'operador' then array['cadastrar_nota', 'editar_card', 'concluir_card', 'escalar_pendencias']
    else array[]::text[]
  end;
$$;

-- 2) Tabela de perfis ----------------------------------------------------------------------------------
create table if not exists public.perfis (
  id bigserial primary key,
  nome text not null,
  nivel text not null check (nivel in ('admin', 'supervisor', 'operador')),
  descricao text,
  permissoes text[] not null default '{}',
  sistema boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists perfis_nome_unico on public.perfis (lower(trim(nome)));
create unique index if not exists perfis_sistema_por_nivel on public.perfis (nivel) where sistema;

insert into public.perfis (nome, nivel, sistema, permissoes, descricao) values
  ('Administrador', 'admin', true, '{}',
   'Acesso total: configura usuários, perfis, obras e empresas, e pode executar qualquer ação no quadro.'),
  ('Supervisor', 'supervisor', true, public.permissoes_do_nivel('supervisor'),
   'Distribui as notas de Entradas para as colunas de tratamento, acompanha a fila da sua coluna, valida o lançamento na Finalização e cadastra obras.'),
  ('Operador', 'operador', true, public.permissoes_do_nivel('operador'),
   'Trata as notas atribuídas a ele na sua coluna: completa os dados, conclui a nota ou encaminha para Pendências quando há problema.')
on conflict do nothing;

-- Garante permissões só do nível (o admin não precisa de lista: tem todas).
create or replace function public.perfis_normaliza()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $$
begin
  new.nome := trim(new.nome);
  if length(new.nome) = 0 then raise exception 'Informe o nome do perfil.' using errcode = '22023'; end if;
  if tg_op = 'UPDATE' and old.sistema then
    new.nivel := old.nivel;   -- perfis de sistema: nível fixo
    new.sistema := true;
  elsif tg_op = 'INSERT' then
    new.sistema := false;     -- só a migração cria perfis de sistema
    if new.nivel = 'admin' then
      raise exception 'Novos perfis devem ser de nível Supervisor ou Operador.' using errcode = '22023';
    end if;
  elsif new.nivel = 'admin' then
    raise exception 'Novos perfis devem ser de nível Supervisor ou Operador.' using errcode = '22023';
  end if;
  new.permissoes := coalesce(array(
    select distinct x from unnest(coalesce(new.permissoes, '{}')) x
    where x = any(public.permissoes_do_nivel(new.nivel)) order by x), '{}');
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists perfis_normaliza_trg on public.perfis;
create trigger perfis_normaliza_trg before insert or update on public.perfis
  for each row execute function public.perfis_normaliza();

alter table public.perfis enable row level security;
drop policy if exists perfis_select on public.perfis;
create policy perfis_select on public.perfis for select to authenticated using (true);
drop policy if exists perfis_insert on public.perfis;
create policy perfis_insert on public.perfis for insert to authenticated
  with check (public.current_is_active() and public."current_role"() = 'admin');
drop policy if exists perfis_update on public.perfis;
create policy perfis_update on public.perfis for update to authenticated
  using (public.current_is_active() and public."current_role"() = 'admin')
  with check (public.current_is_active() and public."current_role"() = 'admin');
drop policy if exists perfis_delete on public.perfis;
create policy perfis_delete on public.perfis for delete to authenticated
  using (public.current_is_active() and public."current_role"() = 'admin' and not sistema);
grant select, insert, update, delete on public.perfis to authenticated;
grant usage, select on sequence public.perfis_id_seq to authenticated;

-- 3) Usuário -> perfil ---------------------------------------------------------------------------------
alter table public.profiles add column if not exists perfil_id bigint references public.perfis(id) on delete restrict;

update public.profiles p set perfil_id = pf.id
  from public.perfis pf
 where pf.sistema and pf.nivel = p.role and p.perfil_id is null;

-- profiles.role acompanha o nível do perfil (e quem ainda grava só o role recebe o perfil de sistema).
create or replace function public.profiles_sincroniza_perfil()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $$
declare
  v_nivel text;
begin
  if new.perfil_id is not null and (tg_op = 'INSERT' or new.perfil_id is distinct from old.perfil_id) then
    select nivel into v_nivel from public.perfis where id = new.perfil_id;
    if v_nivel is null then raise exception 'Perfil não encontrado.' using errcode = 'P0002'; end if;
    new.role := v_nivel;
  elsif tg_op = 'INSERT' or new.role is distinct from old.role then
    if new.role in ('admin', 'supervisor', 'operador') then
      select id into new.perfil_id from public.perfis where sistema and nivel = new.role;
    else
      new.perfil_id := null; -- 'pendente'
    end if;
  end if;
  if new.role = 'admin' then new.coluna := null; end if;
  return new;
end;
$$;
drop trigger if exists profiles_sincroniza_perfil_trg on public.profiles;
create trigger profiles_sincroniza_perfil_trg before insert or update on public.profiles
  for each row execute function public.profiles_sincroniza_perfil();

-- 4) Checagem de permissão -----------------------------------------------------------------------------
create or replace function public.tem_permissao(p_chave text)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $$
  select coalesce((
    select case
      when pr.role = 'admin' then true
      when pr.role not in ('supervisor', 'operador') then false
      else p_chave = any(public.permissoes_do_nivel(pr.role))
           and p_chave = any(coalesce(pf.permissoes, sp.permissoes, '{}'))
    end
    from public.profiles pr
    left join public.perfis pf on pf.id = pr.perfil_id
    left join public.perfis sp on sp.sistema and sp.nivel = pr.role
    where pr.id = auth.uid() and pr.active
  ), false);
$$;
grant execute on function public.tem_permissao(text) to authenticated;

create or replace function public.exigir_permissao(p_chave text)
 returns void
 language plpgsql
 stable
 set search_path to 'public', 'pg_temp'
as $$
begin
  -- rotinas internas do sistema (ex.: reabrir card quando chega CT-e) ligam esta flag só na própria transação
  if coalesce(current_setting('app.permissao_sistema', true), '') = 'true' then
    return;
  end if;
  if not public.tem_permissao(p_chave) then
    raise exception 'Seu perfil não tem permissão para esta ação.' using errcode = '42501';
  end if;
end;
$$;
grant execute on function public.exigir_permissao(text) to authenticated;

-- 5) Aplica as permissões nas rotinas do sistema ------------------------------------------------------
-- Insere "perform public.exigir_permissao('<chave>');" logo no início do corpo de cada função
-- (sem mexer no restante da lógica). Idempotente: não insere de novo se já houver a chamada.
do $$
declare
  r record;
  v_def text;
  v_novo text;
begin
  for r in
    select * from (values
      ('rpc_criar_nota',          'cadastrar_nota'),
      ('rpc_distribuir',          'distribuir_cards'),
      ('rpc_distribuir_lote',     'distribuir_cards'),
      ('rpc_atribuir',            'distribuir_cards'),
      ('rpc_alterar_prioridade',  'alterar_prioridade'),
      ('rpc_validar_lancamento',  'validar_lancamento'),
      ('rpc_reabrir',             'mover_cards'),
      ('rpc_importar_lote',       'importar'),
      ('rpc_vincular_ctes',       'importar'),
      ('rpc_excluir_anexo',       'excluir_anexos'),
      ('rpc_set_obra_validadores','gerenciar_obras')
    ) as t(fn, chave)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fn;
    if v_def is null then
      raise notice 'Função % não encontrada — ignorada.', r.fn;
      continue;
    end if;
    if position('exigir_permissao(' in v_def) > 0 then
      continue;
    end if;
    v_novo := regexp_replace(v_def, '(\n[ \t]*begin[ \t]*\r?\n)',
                             E'\\1  perform public.exigir_permissao(''' || r.chave || E''');\n', 'i');
    if v_novo = v_def then
      raise exception 'Não foi possível aplicar a permissão em %.', r.fn;
    end if;
    execute v_novo;
  end loop;
end;
$$;

-- Reabertura automática do card quando chega o CT-e depois da conclusão é rotina do sistema:
-- não depende da permissão "mover_cards" de quem disparou.
do $$
declare
  v_def text;
  v_novo text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cte_reabrir_em_pendencias';
  if v_def is null or position('app.permissao_sistema' in v_def) > 0 then
    return;
  end if;
  v_novo := replace(v_def, 'perform public.rpc_reabrir(p_nota_id);',
    'perform set_config(''app.permissao_sistema'', ''true'', true);' || E'\n  ' ||
    'perform public.rpc_reabrir(p_nota_id);' || E'\n  ' ||
    'perform set_config(''app.permissao_sistema'', '''', true);');
  if v_novo = v_def then
    raise exception 'Não foi possível ajustar cte_reabrir_em_pendencias.';
  end if;
  execute v_novo;
end;
$$;

-- Mover / concluir / encaminhar para Pendências.
create or replace function public.rpc_mudar_status(p_nota_id bigint, p_status text, p_assigned_to uuid, p_nota_msg text, p_numero_titulo text)
 returns notas
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if p_status = 'concluido' then
    perform public.exigir_permissao('concluir_card');
  elsif p_status = 'pendencias' and public.current_role() = 'operador' then
    perform public.exigir_permissao('escalar_pendencias');
  else
    perform public.exigir_permissao('mover_cards');
  end if;
  if p_status = 'pendencias' and public.current_role() = 'operador' then
    return public.escalar_pendencias_operador(p_nota_id, p_nota_msg);
  end if;
  return public.aplicar_mudanca_status(p_nota_id, p_status, p_assigned_to, p_nota_msg, p_numero_titulo);
end;
$function$;

-- Edição do card: dados gerais exigem "editar_card"; mudar status/responsável pelo formulário
-- exige "mover_cards" / "distribuir_cards".
create or replace function public.rpc_editar_nota(p_nota_id bigint, p_numero text, p_fornecedor text, p_valor numeric, p_data_emissao date, p_descricao text, p_pedido_compras text, p_vencimento date, p_forma_pagamento text, p_frete text, p_obra_id bigint, p_prioridade text, p_origem text, p_destinatario text, p_cnpj_destinatario text, p_frete_cte text, p_frete_transportador text, p_frete_valor numeric, p_frete_forma_pagamento text, p_frete_vencimento date, p_status text, p_assigned_to uuid, p_numero_titulo text)
 returns notas
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nota public.notas;
  v_role text := public.current_role();
  v_coluna text := public.current_coluna();
  v_eh_admin_supervisor boolean := v_role in ('admin', 'supervisor');
  v_frete_norm text := case when p_frete = 'sim' then 'sim' else 'nao' end;
begin
  select * into v_nota from public.notas where id = p_nota_id for update;
  if not found then raise exception 'Nota fiscal não encontrada.' using errcode = 'P0002'; end if;

  if not public.current_is_active() or not (v_eh_admin_supervisor or v_role = 'operador') then
    raise exception 'Você não tem permissão para editar esta nota.' using errcode = '42501';
  end if;
  perform public.exigir_permissao('editar_card');
  if v_role = 'supervisor' and v_coluna is not null and not (v_nota.status in ('entradas','importadas_sienge') or v_nota.status = v_coluna) then
    raise exception 'Você só pode editar notas relacionadas à sua coluna.' using errcode = '42501';
  end if;
  if p_numero is null or p_fornecedor is null or length(trim(p_numero)) = 0 or length(trim(p_fornecedor)) = 0 then
    raise exception 'Informe ao menos o número da nota e o fornecedor.' using errcode = '22023';
  end if;
  if v_eh_admin_supervisor and p_status is not null and p_status <> v_nota.status then
    perform public.exigir_permissao('mover_cards');
  elsif v_eh_admin_supervisor and p_status is not null and p_status = v_nota.status
        and v_nota.status in ('lancamento','financeiro_cx','pendencias') and p_assigned_to is not null
        and p_assigned_to is distinct from v_nota.assigned_to then
    perform public.exigir_permissao('distribuir_cards');
  end if;

  update public.notas set
    numero = trim(p_numero), fornecedor = trim(p_fornecedor), valor = coalesce(p_valor, 0),
    data_emissao = p_data_emissao, descricao = p_descricao, pedido_compras = p_pedido_compras,
    vencimento = p_vencimento, forma_pagamento = p_forma_pagamento, frete = v_frete_norm,
    frete_cte = case when v_frete_norm = 'sim' then p_frete_cte else null end,
    frete_transportador = case when v_frete_norm = 'sim' then p_frete_transportador else null end,
    frete_valor = case when v_frete_norm = 'sim' then p_frete_valor else null end,
    frete_forma_pagamento = case when v_frete_norm = 'sim' then p_frete_forma_pagamento else null end,
    frete_vencimento = case when v_frete_norm = 'sim' then p_frete_vencimento else null end,
    obra_id = p_obra_id,
    destinatario = p_destinatario, cnpj_destinatario = p_cnpj_destinatario,
    prioridade = coalesce(nullif(p_prioridade, ''), prioridade),
    origem = coalesce(nullif(p_origem, ''), origem),
    updated_at = now()
  where id = p_nota_id
  returning * into v_nota;

  if not found then
    raise exception 'Você não tem permissão para editar esta nota.' using errcode = '42501';
  end if;

  perform public.registrar_auditoria('nota_editada', 'nota_fiscal', p_nota_id::text, jsonb_build_object(
    'numero', v_nota.numero, 'fornecedor', v_nota.fornecedor, 'valor', v_nota.valor,
    'obraId', v_nota.obra_id, 'prioridade', v_nota.prioridade, 'origem', v_nota.origem
  ));

  if v_eh_admin_supervisor and p_status is not null and p_status <> v_nota.status then
    v_nota := public.aplicar_mudanca_status(p_nota_id, p_status, p_assigned_to, format('Dados editados por %s', public.profile_name(auth.uid())), p_numero_titulo);
  elsif v_eh_admin_supervisor and p_status is not null and p_status = v_nota.status
        and v_nota.status in ('lancamento','financeiro_cx','pendencias') and p_assigned_to is not null then
    v_nota := public.reatribuir_nota(p_nota_id, p_assigned_to);
  end if;

  return v_nota;
end;
$function$;

-- Edição direta da tabela (fora da RPC): mesma regra de "editar_card" para supervisor/operador.
-- A prioridade fica de fora (tem permissão própria, aplicada em rpc_alterar_prioridade).
create or replace function public.notas_guard_edicao_geral()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_role text := public.current_role();
  v_mudou_dados boolean;
begin
  -- rotinas internas de integração/manutenção (API do estoque, unificação de duplicadas) ligam esta flag só na própria transação
  if coalesce(current_setting('app.integracao', true), '') = 'true' then
    return new;
  end if;
  if v_role = 'admin' then
    return new;
  end if;
  v_mudou_dados := (
    new.numero is distinct from old.numero or new.fornecedor is distinct from old.fornecedor
    or new.valor is distinct from old.valor or new.data_emissao is distinct from old.data_emissao
    or new.descricao is distinct from old.descricao or new.pedido_compras is distinct from old.pedido_compras
    or new.vencimento is distinct from old.vencimento or new.forma_pagamento is distinct from old.forma_pagamento
    or new.frete is distinct from old.frete or new.obra_id is distinct from old.obra_id
    or new.origem is distinct from old.origem
    or new.destinatario is distinct from old.destinatario or new.cnpj_destinatario is distinct from old.cnpj_destinatario
    or new.frete_cte is distinct from old.frete_cte or new.frete_transportador is distinct from old.frete_transportador
    or new.frete_valor is distinct from old.frete_valor or new.frete_forma_pagamento is distinct from old.frete_forma_pagamento
    or new.frete_vencimento is distinct from old.frete_vencimento
  );
  if v_role in ('supervisor', 'operador') then
    if v_mudou_dados and not public.tem_permissao('editar_card') then
      raise exception 'Seu perfil não tem permissão para editar os dados desta nota fiscal.' using errcode = '42501';
    end if;
    return new;
  end if;
  if coalesce(new.obra_id, old.obra_id) is not null
     and public.is_validador_da_obra(coalesce(new.obra_id, old.obra_id)) then
    return new;
  end if;
  if v_mudou_dados or new.prioridade is distinct from old.prioridade then
    raise exception 'Você não tem permissão para editar os dados desta nota fiscal.' using errcode = '42501';
  end if;
  return new;
end;
$function$;

-- 6) Telas protegidas por regra de acesso (RLS) --------------------------------------------------------
drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log for select
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('ver_auditoria'))));

drop policy if exists obras_write on public.obras;
create policy obras_write on public.obras for all
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('gerenciar_obras'))))
  with check (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('gerenciar_obras'))));

drop policy if exists obra_cnpjs_write on public.obra_cnpjs;
create policy obra_cnpjs_write on public.obra_cnpjs for all
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('gerenciar_obras'))))
  with check (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('gerenciar_obras'))));

drop policy if exists obra_validadores_write on public.obra_validadores;
create policy obra_validadores_write on public.obra_validadores for all
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('gerenciar_obras'))))
  with check (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('gerenciar_obras'))));

drop policy if exists anexos_delete on public.anexos;
create policy anexos_delete on public.anexos for delete
  using (public.current_is_active() and (uploaded_by = auth.uid() or public."current_role"() = 'admin'
         or (public."current_role"() = 'supervisor' and public.tem_permissao('excluir_anexos'))));
