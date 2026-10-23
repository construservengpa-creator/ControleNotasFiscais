-- 🔓 Encerramento do card do CT-e liberado pela trava de campos sensíveis
-- (aplicar depois de 20261019_cte_vinculo_inverso.sql).
--
-- O gatilho notas_guard_campos_sensiveis só deixa mudar status, responsável,
-- homologação, validação do lançamento e nº do título com app.rpc_call = 'true'
-- (como faz aplicar_mudanca_status). cte_encerrar_card mudava o status do card do
-- CT-e direto, sem esse sinal, e era barrado com "Mudança de status, responsável ou
-- homologação só pode ser feita pelas rotinas do sistema.":
--   * ao anexar o XML do CT-e cujas notas fiscais já estão cadastradas, a análise
--     inteira era desfeita e o card ficava sem o XML;
--   * no vínculo automático ao gravar a nota fiscal, o frete ia para a nota, mas o
--     card do CT-e ficava aberto (o erro só virava um aviso no log).
--
-- Não usa aplicar_mudanca_status porque ela exige o nº do título para concluir e
-- registra a conclusão como tratamento da nota — aqui o card só é encerrado.

create or replace function public.cte_encerrar_card(p_card_id bigint, p_lista_nfs text, p_como text)
 returns void
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_rpc_call text := coalesce(current_setting('app.rpc_call', true), '');
begin
  perform set_config('app.cte_analise', 'true', true);
  perform set_config('app.rpc_call', 'true', true);
  update public.notas set
    status = 'concluido', completed_at = now(),
    lancamento_validado_por = auth.uid(), lancamento_validado_em = now(),
    lancamento_validado_obs = 'CT-e vinculado à(s) NF ' || p_lista_nfs || ' — card encerrado automaticamente; o lançamento do frete segue na(s) nota(s) fiscal(is).',
    descricao = trim(coalesce(descricao, '') || ' CT-e vinculado à(s) NF ' || p_lista_nfs || ' ' || p_como || '.')
  where id = p_card_id and status is distinct from 'concluido';
  perform set_config('app.rpc_call', v_rpc_call, true);
  perform set_config('app.cte_analise', 'false', true);
end;
$function$;
revoke all on function public.cte_encerrar_card(bigint, text, text) from public, anon, authenticated;

-- Cards de CT-e que ficaram abertos porque o encerramento era barrado, embora o frete
-- já esteja gravado em nota(s) fiscal(is): encerra agora.
select public.cte_encerrar_card(c.id, c.lista, 'na correção do encerramento automático')
  from (select card.id, string_agg(nf.numero, ', ' order by nf.id) as lista
          from public.notas card
          join public.notas nf on nf.frete_cte_chave = regexp_replace(card.chave_acesso, '\D', '', 'g')
                              and not public.chave_e_cte(nf.chave_acesso)
         where public.chave_e_cte(card.chave_acesso)
           and card.status is distinct from 'concluido'
         group by card.id) c;
