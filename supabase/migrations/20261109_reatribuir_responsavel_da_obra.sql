-- "Atribuir a…" do card: permitir atribuir a nota a um responsável pela validação de recebimento da obra
-- mesmo quando quem está atribuindo (admin/supervisor) NÃO é responsável por essa obra.
--
-- Erro corrigido: a checagem de "responsável vinculado à obra" chamava public.is_validador_da_obra(obra_id),
-- que verifica o USUÁRIO LOGADO, e não a pessoa escolhida. Resultado: o admin/supervisor recebia
-- "Selecione um operador ativo da coluna atual da nota, ou um responsável vinculado à obra desta nota."
-- ao escolher, por exemplo, o responsável pela obra numa nota em Pendências.
-- A pessoa escolhida continua sendo validada pelo exists em obra_validadores (user_id = p_assigned_to).
-- O restante da função é idêntico ao que estava no banco. Pode rodar de novo sem problema.

create or replace function public.reatribuir_nota(p_nota_id bigint, p_assigned_to uuid)
 returns notas
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nota public.notas;
  v_role text := public.current_role();
  v_coluna text := public.current_coluna();
  v_operador public.profiles;
  v_eh_operador_da_coluna boolean;
  v_eh_validador_obra boolean;
  v_novo_id uuid;
begin
  select * into v_nota from public.notas where id = p_nota_id for update;
  if not found then raise exception 'Nota fiscal não encontrada.' using errcode = 'P0002'; end if;

  if v_role = 'supervisor' and v_coluna is not null and v_coluna <> v_nota.status then
    raise exception 'Você só pode reatribuir notas da sua própria coluna.' using errcode = '42501';
  end if;

  v_novo_id := null;
  if p_assigned_to is not null then
    select * into v_operador from public.profiles where id = p_assigned_to;
    v_eh_operador_da_coluna := v_operador.id is not null and v_operador.role = 'operador' and v_operador.coluna = v_nota.status and v_operador.active;
    v_eh_validador_obra := v_operador.id is not null and v_operador.active and v_nota.obra_id is not null and exists (
      select 1 from public.obra_validadores where obra_id = v_nota.obra_id and user_id = p_assigned_to
    );
    if v_operador.id is null or not (v_eh_operador_da_coluna or v_eh_validador_obra) then
      raise exception 'Selecione um operador ativo da coluna atual da nota, ou um responsável vinculado à obra desta nota.' using errcode = '22023';
    end if;
    v_novo_id := v_operador.id;
  end if;

  if v_novo_id is not distinct from v_nota.assigned_to then
    return v_nota;
  end if;

  perform set_config('app.rpc_call', 'true', true);
  update public.notas set assigned_to = v_novo_id, assigned_at = case when v_novo_id is not null then now() else null end, updated_at = now()
  where id = p_nota_id returning * into v_nota;

  insert into public.movements (nota_id, from_status, to_status, assigned_to, moved_by, method, note)
  values (p_nota_id, v_nota.status, v_nota.status, v_novo_id, auth.uid(), 'reatribuicao',
    case when v_novo_id is not null then format('Reatribuída para %s', public.profile_name(v_novo_id)) else 'Atribuição removida' end);

  perform public.registrar_auditoria('nota_reatribuida', 'nota_fiscal', p_nota_id::text,
    jsonb_build_object('assignedTo', v_novo_id));

  return v_nota;
end;
$function$;
