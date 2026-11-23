-- Perfis: todas as funções liberadas para configurar em qualquer perfil.
--
-- Antes, um perfil de nível Operador só podia receber as permissões de operador. Agora qualquer perfil
-- (Supervisor ou Operador) pode receber qualquer permissão. Quando um usuário de nível Operador tem
-- uma permissão "de supervisor" (mover, distribuir, prioridade, validar lançamento, importar, obras...),
-- o banco o trata como SUPERVISOR DA COLUNA DELE naquela ação (mesmas restrições de coluna).
--
-- Nova permissão "ver_cards_coluna" (só nível Operador): enxergar todos os cards de Entradas,
-- Importadas SIENGE, Finalização e da coluna dele — como o supervisor — em vez de só os atribuídos a ele.
-- Sem ela, um operador com "distribuir" ou "mover" não enxerga os cards de Entradas.

-- 1) Catálogo: todas as permissões para os dois níveis ------------------------------------------------
create or replace function public.permissoes_do_nivel(p_nivel text)
 returns text[]
 language sql
 immutable
as $$
  select case
    when p_nivel in ('supervisor', 'operador') then
      array['cadastrar_nota', 'editar_card', 'concluir_card', 'escalar_pendencias', 'mover_cards', 'distribuir_cards',
            'alterar_prioridade', 'validar_lancamento', 'excluir_anexos', 'importar',
            'gerenciar_obras', 'ver_auditoria', 'ver_usuarios']
      || case when p_nivel = 'operador' then array['ver_cards_coluna'] else array[]::text[] end
    else array[]::text[]
  end;
$$;

-- O perfil de sistema Supervisor também pode encaminhar para Pendências (já podia, pelo "mover").
update public.perfis set permissoes = permissoes || array['escalar_pendencias']
 where sistema and nivel = 'supervisor' and not ('escalar_pendencias' = any(permissoes));

-- 2) Papel usado dentro das ações já autorizadas --------------------------------------------------------
-- Operador com a permissão da ação age como supervisor da sua coluna (as funções abaixo já checam
-- a permissão com exigir_permissao antes de chegar aqui).
create or replace function public.papel_para_acao()
 returns text
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $$
  select case when public."current_role"() = 'operador' then 'supervisor' else public."current_role"() end;
$$;
grant execute on function public.papel_para_acao() to authenticated;

do $$
declare
  r record;
  v_def text;
  v_novo text;
begin
  for r in
    select unnest(array['rpc_alterar_prioridade', 'rpc_atribuir', 'rpc_distribuir', 'rpc_distribuir_lote', 'rpc_excluir_anexo',
                        'rpc_importar_lote', 'rpc_reabrir', 'rpc_set_obra_validadores', 'rpc_validar_lancamento',
                        'rpc_vincular_ctes', 'reatribuir_nota']) as fn
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fn;
    if v_def is null or position('papel_para_acao()' in v_def) > 0 then
      continue;
    end if;
    v_novo := replace(v_def, 'v_role text := public.current_role();', 'v_role text := public.papel_para_acao();');
    v_novo := replace(v_novo, 'public."current_role"() not in (''admin'', ''supervisor'')', 'public.papel_para_acao() not in (''admin'', ''supervisor'')');
    if v_novo = v_def then
      raise exception 'Não foi possível ajustar %.', r.fn;
    end if;
    execute v_novo;
  end loop;
end;
$$;

-- reatribuir_nota só é chamada depois da checagem de "distribuir_cards" (rpc_atribuir / rpc_editar_nota).

-- 3) Mover / concluir / encaminhar --------------------------------------------------------------------
-- Regras de transição: operador com "mover_cards" segue as regras do supervisor da coluna dele.
do $$
declare
  v_def text;
  v_novo text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'avaliar_transicao_status';
  if position('tem_permissao(''mover_cards'')' in v_def) > 0 then
    return;
  end if;
  v_novo := replace(v_def, 'v_role text := public.current_role();',
    'v_role text := case when public.current_role() = ''operador'' and public.tem_permissao(''mover_cards'') then ''supervisor'' else public.current_role() end;');
  if v_novo = v_def then
    raise exception 'Não foi possível ajustar avaliar_transicao_status.';
  end if;
  execute v_novo;
end;
$$;

create or replace function public.rpc_mudar_status(p_nota_id bigint, p_status text, p_assigned_to uuid, p_nota_msg text, p_numero_titulo text)
 returns notas
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if p_status = 'concluido' then
    perform public.exigir_permissao('concluir_card');
  elsif p_status = 'pendencias' then
    if not (public.tem_permissao('escalar_pendencias') or public.tem_permissao('mover_cards')) then
      perform public.exigir_permissao('escalar_pendencias');
    end if;
  else
    perform public.exigir_permissao('mover_cards');
  end if;
  -- Operador sem "mover_cards" encaminha para Pendências pelo fluxo próprio (só os cards atribuídos a ele).
  if p_status = 'pendencias' and public.current_role() = 'operador' and not public.tem_permissao('mover_cards') then
    return public.escalar_pendencias_operador(p_nota_id, p_nota_msg);
  end if;
  return public.aplicar_mudanca_status(p_nota_id, p_status, p_assigned_to, p_nota_msg, p_numero_titulo);
end;
$function$;

-- Editar: operador com "mover_cards"/"distribuir_cards" também pode mudar status/responsável pelo formulário.
do $$
declare
  v_def text;
  v_novo text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rpc_editar_nota';
  if position('v_pode_fluxo' in v_def) > 0 then
    return;
  end if;
  v_novo := replace(v_def, 'v_eh_admin_supervisor boolean := v_role in (''admin'', ''supervisor'');',
    'v_eh_admin_supervisor boolean := v_role in (''admin'', ''supervisor'');' || E'\n  ' ||
    'v_pode_fluxo boolean := v_role in (''admin'', ''supervisor'') or (v_role = ''operador'' and (public.tem_permissao(''mover_cards'') or public.tem_permissao(''distribuir_cards'')));');
  -- as decisões de status/responsável (depois da checagem de acesso) passam a usar v_pode_fluxo
  v_novo := replace(v_novo, 'if v_eh_admin_supervisor and p_status is not null', 'if v_pode_fluxo and p_status is not null');
  v_novo := replace(v_novo, 'elsif v_eh_admin_supervisor and p_status is not null', 'elsif v_pode_fluxo and p_status is not null');
  if v_novo = v_def then
    raise exception 'Não foi possível ajustar rpc_editar_nota.';
  end if;
  execute v_novo;
end;
$$;

-- 4) O que o usuário enxerga e pode gravar (RLS) --------------------------------------------------------
drop policy if exists notas_select on public.notas;
create policy notas_select on public.notas for select
  using (public.current_is_active() and (
    public."current_role"() = 'admin'
    or (public."current_role"() = 'supervisor' and (
          public.current_coluna() is null
          or status = any (array['entradas', 'importadas_sienge', 'concluido'])
          or status = public.current_coluna()
          or (obra_id is not null and public.is_validador_da_obra(obra_id))))
    or (public."current_role"() = 'operador' and (
          assigned_to = auth.uid() or created_by = auth.uid()
          or (obra_id is not null and public.is_validador_da_obra(obra_id))
          or (public.tem_permissao('ver_cards_coluna') and (
                status = any (array['entradas', 'importadas_sienge', 'concluido'])
                or status = public.current_coluna()))))
  ));

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid()
    or public."current_role"() = 'admin'
    or (public."current_role"() = 'supervisor' and (public.current_coluna() is null or coluna = public.current_coluna()))
    or (public."current_role"() = 'operador'
        and (public.tem_permissao('distribuir_cards') or public.tem_permissao('ver_usuarios'))
        and coluna = public.current_coluna()));

drop policy if exists distribution_state_write on public.distribution_state;
create policy distribution_state_write on public.distribution_state for update
  using (public.current_is_active() and (public."current_role"() in ('admin', 'supervisor')
         or (public."current_role"() = 'operador' and public.tem_permissao('distribuir_cards'))))
  with check (public.current_is_active() and (public."current_role"() in ('admin', 'supervisor')
         or (public."current_role"() = 'operador' and public.tem_permissao('distribuir_cards'))));

drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log for select
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('ver_auditoria'))));

drop policy if exists obras_write on public.obras;
create policy obras_write on public.obras for all
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('gerenciar_obras'))))
  with check (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('gerenciar_obras'))));

drop policy if exists obra_cnpjs_write on public.obra_cnpjs;
create policy obra_cnpjs_write on public.obra_cnpjs for all
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('gerenciar_obras'))))
  with check (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('gerenciar_obras'))));

drop policy if exists obra_validadores_write on public.obra_validadores;
create policy obra_validadores_write on public.obra_validadores for all
  using (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('gerenciar_obras'))))
  with check (public.current_is_active() and (public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('gerenciar_obras'))));

drop policy if exists anexos_delete on public.anexos;
create policy anexos_delete on public.anexos for delete
  using (public.current_is_active() and (uploaded_by = auth.uid() or public."current_role"() = 'admin'
         or (public."current_role"() in ('supervisor', 'operador') and public.tem_permissao('excluir_anexos'))));
