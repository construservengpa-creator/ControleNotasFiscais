-- 🚚 Exclusão dos CT-es do CONSÓRCIO MAGUARI (CNPJ 57.080.615/0001-92) importados do relatório SIENGE.
--
-- Apaga os cards próprios de CT-e (chave de acesso modelo 57) cujo tomador/destinatário é o
-- Consórcio Maguari. A exclusão leva junto, em cascata, os anexos (metadados), comentários e
-- demais registros ligados ao card — igual ao botão "Excluir" da tela de notas.
-- Os arquivos dos anexos no Storage (bucket dos anexos) não são apagados por aqui; os caminhos
-- ficam registrados no audit_log (details.anexos) caso seja preciso limpá-los.
--
-- As notas fiscais do consórcio que apenas RECEBERAM os dados de um CT-e no frete (frete_cte_chave)
-- não são apagadas. Para desfazer também esses vínculos, rode o bloco opcional no fim do arquivo.
--
-- Conferir antes de rodar:
--   select id, numero, fornecedor, destinatario, status, valor
--     from public.notas
--    where substr(regexp_replace(coalesce(chave_acesso, ''), '\D', '', 'g'), 21, 2) = '57'
--      and (regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g') = '57080615000192'
--           or destinatario ilike '%maguari%');

do $$
declare
  v_qtd integer;
begin
  with alvo as (
    select n.*
      from public.notas n
     where length(regexp_replace(coalesce(n.chave_acesso, ''), '\D', '', 'g')) = 44
       and substr(regexp_replace(n.chave_acesso, '\D', '', 'g'), 21, 2) = '57'
       and (regexp_replace(coalesce(n.cnpj_destinatario, ''), '\D', '', 'g') = '57080615000192'
            or n.destinatario ilike '%maguari%')
  ), log as (
    insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
    select null, 'Script de manutenção', 'cte_excluido_maguari', 'nota_fiscal', a.id::text,
           jsonb_build_object('numero', a.numero, 'fornecedor', a.fornecedor, 'destinatario', a.destinatario,
                              'chaveAcesso', a.chave_acesso, 'valor', a.valor, 'status', a.status,
                              'anexos', (select coalesce(jsonb_agg(x.storage_path), '[]'::jsonb)
                                           from public.anexos x where x.nota_id = a.id))
      from alvo a
    returning entity_id
  )
  delete from public.notas n using log where n.id = log.entity_id::bigint;
  get diagnostics v_qtd = row_count;
  raise notice 'CT-es do Consórcio Maguari excluídos: %', v_qtd;
end $$;

-- ---------------------------------------------------------------------------------------------
-- OPCIONAL — desfaz o vínculo dos CT-es gravados pela importação nas notas fiscais do consórcio
-- (a nota continua; sai só a chave do CT-e e o aviso "lançamento do frete pendente").
-- ---------------------------------------------------------------------------------------------
-- update public.notas n
--    set frete_cte_chave = null, frete_lancamento_pendente = false
--  where n.frete_cte_chave is not null
--    and (regexp_replace(coalesce(n.cnpj_destinatario, ''), '\D', '', 'g') = '57080615000192'
--         or n.destinatario ilike '%maguari%')
--    and exists (select 1 from public.audit_log l
--                 where l.action = 'cte_vinculado' and l.entity_id = n.id::text
--                   and l.details->>'chave' = n.frete_cte_chave);
