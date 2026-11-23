-- Operador passa a poder editar os dados gerais de qualquer card que enxerga no quadro
-- (antes só quando era validador da obra da nota).
-- Continua valendo:
--   * o acesso por empresa/obra (política RESTRICTIVE notas_acesso_empresa_update);
--   * status, responsável, homologação e nº do título só mudam pelas rotinas do sistema
--     (gatilho notas_guard_campos_sensiveis) — o operador não muda isso pelo "Editar".

-- 1) Regra de UPDATE: operador ativo pode atualizar os cards que enxerga.
drop policy if exists notas_update on public.notas;
create policy notas_update on public.notas for update
  using (
    public.current_is_active() and (
      public."current_role"() = 'admin'
      or (public."current_role"() = 'supervisor' and (
            public.current_coluna() is null
            or status = any (array['entradas', 'importadas_sienge', 'concluido'])
            or status = public.current_coluna()
            or (obra_id is not null and public.is_validador_da_obra(obra_id))))
      or public."current_role"() = 'operador'
    )
  );

-- 2) Gatilho que bloqueava a edição de dados gerais por quem não era validador da obra.
create or replace function public.notas_guard_edicao_geral()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_role text := public.current_role();
begin
  -- rotinas internas de integração/manutenção (API do estoque, unificação de duplicadas) ligam esta flag só na própria transação
  if coalesce(current_setting('app.integracao', true), '') = 'true' then
    return new;
  end if;
  if v_role in ('admin', 'supervisor', 'operador') then
    return new;
  end if;
  if coalesce(new.obra_id, old.obra_id) is not null
     and public.is_validador_da_obra(coalesce(new.obra_id, old.obra_id)) then
    return new;
  end if;
  if (
    new.numero is distinct from old.numero or new.fornecedor is distinct from old.fornecedor
    or new.valor is distinct from old.valor or new.data_emissao is distinct from old.data_emissao
    or new.descricao is distinct from old.descricao or new.pedido_compras is distinct from old.pedido_compras
    or new.vencimento is distinct from old.vencimento or new.forma_pagamento is distinct from old.forma_pagamento
    or new.frete is distinct from old.frete or new.obra_id is distinct from old.obra_id
    or new.prioridade is distinct from old.prioridade or new.origem is distinct from old.origem
    or new.destinatario is distinct from old.destinatario or new.cnpj_destinatario is distinct from old.cnpj_destinatario
    or new.frete_cte is distinct from old.frete_cte or new.frete_transportador is distinct from old.frete_transportador
    or new.frete_valor is distinct from old.frete_valor or new.frete_forma_pagamento is distinct from old.frete_forma_pagamento
    or new.frete_vencimento is distinct from old.frete_vencimento
  ) then
    raise exception 'Você não tem permissão para editar os dados desta nota fiscal.'
      using errcode = '42501';
  end if;
  return new;
end;
$function$;

-- 3) RPC de edição: operador edita dados gerais; status/responsável seguem só para admin/supervisor.
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
  if v_role = 'supervisor' and v_coluna is not null and not (v_nota.status in ('entradas','importadas_sienge') or v_nota.status = v_coluna) then
    raise exception 'Você só pode editar notas relacionadas à sua coluna.' using errcode = '42501';
  end if;
  if p_numero is null or p_fornecedor is null or length(trim(p_numero)) = 0 or length(trim(p_fornecedor)) = 0 then
    raise exception 'Informe ao menos o número da nota e o fornecedor.' using errcode = '22023';
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
