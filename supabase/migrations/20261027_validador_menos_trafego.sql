-- ⚡ Validador de NF: menos dados trafegando ao abrir a tela.
-- (aplicar depois de 20261021_validador_desempenho.sql; pode rodar de novo sem problema)
--
-- Antes, a cada abertura o navegador baixava a base inteira (13 mil notas) e depois mandava de volta
-- todas as chaves, de 150 em 150, para achar os cards (~90 requisições) e os dados de Pedido/Responsável
-- (~90 requisições). Agora:
--   * o navegador guarda a base em cache e só pede as notas com atualizado_em mais novo que o do cache
--     (índice abaixo);
--   * os cards das notas da base vêm desta função, que cruza as chaves no próprio banco — em páginas de
--     5.000, continuando do último id, em formato compacto (sem repetir o nome dos campos).
-- A função roda com as permissões de quem chama (RLS da tabela notas continua valendo).

create index if not exists validador_nf_notas_atualizado_idx on public.validador_nf_notas (atualizado_em);

-- Devolve um array de linhas compactas [id, numero, fornecedor, status, assigned_to, chave_acesso,
-- numero_titulo, obra_id, created_by], até 5.000 por chamada, a partir do id informado.
drop function if exists public.validador_cards_da_base(bigint);
create or replace function public.validador_cards_da_base(p_apos_id bigint default 0)
 returns jsonb
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_array(c.id, c.numero, c.fornecedor, c.status, c.assigned_to, c.chave_acesso,
                                              c.numero_titulo, c.obra_id, c.created_by) order by c.id), '[]'::jsonb)
    from (select n.id, n.numero, n.fornecedor, n.status, n.assigned_to, n.chave_acesso, n.numero_titulo, n.obra_id, n.created_by
            from public.notas n
           where n.id > coalesce(p_apos_id, 0)
             and n.chave_acesso is not null
             and exists (select 1 from public.validador_nf_notas v
                          where v.chave = upper(regexp_replace(n.chave_acesso, '[^0-9A-Za-z]', '', 'g')))
           order by n.id
           limit 5000) c;
$function$;

revoke all on function public.validador_cards_da_base(bigint) from public, anon;
grant execute on function public.validador_cards_da_base(bigint) to authenticated;
