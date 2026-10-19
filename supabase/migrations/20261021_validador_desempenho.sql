-- ⚡ Validador de NF: leitura da base salva sem estourar o tempo limite ("canceling statement due to statement
-- timeout"). Aplicar depois de 20261020_validador_base_relatorio.sql; pode rodar de novo sem problema.
--
-- As regras de acesso das tabelas do validador chamavam public.current_is_active() uma vez POR LINHA (13 mil
-- linhas por leitura). Com (select …) o Postgres calcula uma vez só por consulta — é a forma recomendada pelo
-- Supabase para funções em políticas de RLS. Os índices ajudam a achar os cards pela chave e pelo número.

alter policy validador_nf_notas_select on public.validador_nf_notas
  using ((select public.current_is_active()));
alter policy validador_nf_cargas_select on public.validador_nf_cargas
  using ((select public.current_is_active()));

alter policy validador_nf_dados_select on public.validador_nf_dados
  using ((select public.current_is_active()));
alter policy validador_nf_dados_insert on public.validador_nf_dados
  with check ((select public.current_is_active()));
alter policy validador_nf_dados_update on public.validador_nf_dados
  using ((select public.current_is_active())) with check ((select public.current_is_active()));

alter policy validador_relatorios_select on storage.objects
  using (bucket_id = 'validador-relatorios' and (select public.current_is_active()));

create index if not exists notas_chave_acesso_idx on public.notas (chave_acesso);
create index if not exists notas_numero_idx on public.notas (numero);

analyze public.validador_nf_notas;
analyze public.validador_nf_cargas;
