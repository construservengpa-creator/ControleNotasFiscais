-- Libera o operador para escalar a nota dele para Pendências.
--
-- O botão "Escalar p/ Pendências" já aparecia para o operador responsável,
-- mas a chamada falhava no banco: rpc_mudar_status roda com as permissões
-- de quem chama (RLS), e o operador
--   * não enxerga os perfis da coluna Pendências (profiles_select), então o
--     rodízio em escolher_proximo_operador não achava ninguém ("Não há
--     operadores ativos cadastrados nesta coluna.");
--   * não pode avançar o rodízio em distribution_state (só admin/supervisor);
--   * não pode gravar a nota já reatribuída a outra pessoa (notas_update), nem
--     o movimento correspondente.
--
-- A escalada do operador passa a rodar por uma função SECURITY DEFINER que
-- valida antes, explicitamente, as mesmas regras de avaliar_transicao_status
-- para o operador (ativo, nota atribuída a ele, na coluna de trabalho dele,
-- e essa coluna não é Pendências). Os demais perfis/transições continuam
-- exatamente como antes, sob RLS.

create or replace function public.escalar_pendencias_operador(p_nota_id bigint, p_nota_msg text)
returns public.notas
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nota public.notas;
  v_coluna text := public.current_coluna();
begin
  if not public.current_is_active() or public.current_role() <> 'operador' then
    raise exception 'Apenas operadores ativos podem escalar notas por esta via.' using errcode = '42501';
  end if;
  select * into v_nota from public.notas where id = p_nota_id;
  if not found then raise exception 'Nota fiscal não encontrada.' using errcode = 'P0002'; end if;
  if v_nota.assigned_to is distinct from auth.uid() then
    raise exception 'Esta nota não está atribuída a você.' using errcode = '42501';
  end if;
  if v_nota.status is distinct from v_coluna or v_coluna not in ('lancamento', 'financeiro_cx') then
    raise exception 'Você só pode escalar notas que estão na sua coluna de trabalho.' using errcode = '42501';
  end if;
  return public.aplicar_mudanca_status(p_nota_id, 'pendencias', null, p_nota_msg, null);
end;
$function$;

revoke all on function public.escalar_pendencias_operador(bigint, text) from public, anon;
grant execute on function public.escalar_pendencias_operador(bigint, text) to authenticated;

create or replace function public.rpc_mudar_status(p_nota_id bigint, p_status text, p_assigned_to uuid, p_nota_msg text, p_numero_titulo text)
returns public.notas
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  if p_status = 'pendencias' and public.current_role() = 'operador' then
    return public.escalar_pendencias_operador(p_nota_id, p_nota_msg);
  end if;
  return public.aplicar_mudanca_status(p_nota_id, p_status, p_assigned_to, p_nota_msg, p_numero_titulo);
end;
$function$;
