-- 🚚 Cards de frete (CT-e) no Validador de NF (aplicar depois de 20261105_validador_acesso_por_empresa.sql).
--
-- O Validador passa a mostrar, junto com as notas do relatório de NF-e, os cards de CT-e do Controle de
-- Notas (chave modelo 57) que não foram encerrados pelo vínculo com a nota fiscal. A leitura dos cards já
-- segue as regras de acesso da tabela notas — não precisa de nada novo.
--
-- Pedido, Responsável e Comprador (validador_nf_dados) só podiam ser gravados, por quem não vê todas as
-- empresas, para chaves que estão na base do relatório (validador_nf_notas). Agora valem também para a
-- chave de um card de CT-e que o usuário enxerga (a consulta em notas passa pelas regras de acesso dela).

create or replace function public.validador_chave_visivel(p_chave text)
 returns boolean
 language sql
 stable
 security invoker
 set search_path to 'public', 'pg_temp'
as $function$
  select exists (select 1 from public.validador_nf_notas v where v.chave = p_chave)
      or (public.chave_e_cte(p_chave)
          and exists (select 1 from public.notas n where n.chave_acesso = p_chave));
$function$;
revoke all on function public.validador_chave_visivel(text) from public, anon;
grant execute on function public.validador_chave_visivel(text) to authenticated;

alter policy validador_nf_dados_select on public.validador_nf_dados
  using ((select public.current_is_active())
         and ((select public.validador_ve_tudo()) or public.validador_chave_visivel(validador_nf_dados.chave)));
alter policy validador_nf_dados_insert on public.validador_nf_dados
  with check ((select public.current_is_active())
         and ((select public.validador_ve_tudo()) or public.validador_chave_visivel(validador_nf_dados.chave)));
alter policy validador_nf_dados_update on public.validador_nf_dados
  using ((select public.current_is_active())
         and ((select public.validador_ve_tudo()) or public.validador_chave_visivel(validador_nf_dados.chave)))
  with check ((select public.current_is_active())
         and ((select public.validador_ve_tudo()) or public.validador_chave_visivel(validador_nf_dados.chave)));
