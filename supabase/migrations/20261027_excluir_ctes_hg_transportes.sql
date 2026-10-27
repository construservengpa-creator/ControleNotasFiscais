-- 🚚 Exclusão dos CT-es da HG TRANSPORTES (emitente) importados do relatório SIENGE.
--
-- Apaga os cards próprios de CT-e (chave de acesso modelo 57) cujo emitente/fornecedor é a HG Transportes
-- ("H G TRANSPORTES", "HG TRANSPORTE E LOCACAO LTDA" etc.). A exclusão leva junto, em cascata, os anexos
-- (metadados), comentários e demais registros ligados ao card — igual ao botão "Excluir" da tela de notas.
-- Os arquivos dos anexos no Storage não são apagados por aqui; os caminhos ficam no audit_log
-- (action = 'cte_excluido_hg', details.anexos).
--
-- As notas fiscais que apenas RECEBERAM os dados de um CT-e da HG no frete (frete_cte_chave) não são
-- apagadas. Para desfazer também esses vínculos, rode o bloco opcional no fim do arquivo.
--
-- Conferir antes de rodar (mesmo filtro da exclusão):
--   select id, numero, fornecedor, destinatario, status, valor
--     from public.notas
--    where length(regexp_replace(coalesce(chave_acesso, ''), '\D', '', 'g')) = 44
--      and substr(regexp_replace(chave_acesso, '\D', '', 'g'), 21, 2) = '57'
--      and fornecedor ~* '^\s*h\.?\s*g\.?\s+transport';

do $$
declare
  v_qtd integer;
begin
  with alvo as (
    select n.*
      from public.notas n
     where length(regexp_replace(coalesce(n.chave_acesso, ''), '\D', '', 'g')) = 44
       and substr(regexp_replace(n.chave_acesso, '\D', '', 'g'), 21, 2) = '57'
       and n.fornecedor ~* '^\s*h\.?\s*g\.?\s+transport'
  ), log as (
    insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
    select null, 'Script de manutenção', 'cte_excluido_hg', 'nota_fiscal', a.id::text,
           jsonb_build_object('numero', a.numero, 'fornecedor', a.fornecedor, 'destinatario', a.destinatario,
                              'chaveAcesso', a.chave_acesso, 'valor', a.valor, 'status', a.status,
                              'anexos', (select coalesce(jsonb_agg(x.storage_path), '[]'::jsonb)
                                           from public.anexos x where x.nota_id = a.id))
      from alvo a
    returning entity_id
  )
  delete from public.notas n using log where n.id = log.entity_id::bigint;
  get diagnostics v_qtd = row_count;
  raise notice 'CT-es da HG Transportes excluídos: %', v_qtd;
end $$;

-- ---------------------------------------------------------------------------------------------
-- OPCIONAL — desfaz o vínculo dos CT-es da HG gravados pela importação nas notas fiscais
-- (a nota continua; sai só a chave do CT-e e o aviso "lançamento do frete pendente").
-- Conferir antes:
--   select n.id, n.numero, n.fornecedor, n.frete_cte, n.frete_transportador, n.status
--     from public.notas n
--    where n.frete_cte_chave is not null
--      and exists (select 1 from public.audit_log l
--                   where l.action = 'cte_vinculado' and l.entity_id = n.id::text
--                     and l.details->>'chave' = n.frete_cte_chave
--                     and l.details->>'emitente' ~* '^\s*h\.?\s*g\.?\s+transport');
-- ---------------------------------------------------------------------------------------------
-- update public.notas n
--    set frete_cte_chave = null, frete_lancamento_pendente = false
--  where n.frete_cte_chave is not null
--    and exists (select 1 from public.audit_log l
--                 where l.action = 'cte_vinculado' and l.entity_id = n.id::text
--                   and l.details->>'chave' = n.frete_cte_chave
--                   and l.details->>'emitente' ~* '^\s*h\.?\s*g\.?\s+transport');
