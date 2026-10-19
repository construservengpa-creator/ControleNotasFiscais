-- 🗄️ Validador de NF: base salva do relatório de NF-e do SIENGE, atualizada a cada novo relatório.
-- (aplicar depois de 20261019_validador_pedido_responsavel_comprador.sql; pode rodar de novo sem problema)
--
-- Cada nota fica uma vez só, pela chave de acesso. A cada relatório carregado (por admin/supervisor):
--   * nota nova entra;
--   * nota que já existia é atualizada (manifesto, título, escrituração…) — guarda em qual carga mudou
--     por último e desde quando tem título;
--   * nota que não veio no relatório continua na base (o validador mostra "não veio no último relatório").
-- O arquivo original de cada carga fica no armazenamento privado "validador-relatorios".
-- Leitura: qualquer usuário ativo. Gravação: só pelas funções abaixo, para admin/supervisor.

create table if not exists public.validador_nf_cargas (
  id           bigint generated always as identity primary key,
  arquivo      text not null check (length(btrim(arquivo)) between 1 and 200),
  arquivo_path text,
  enviado_por  uuid not null default auth.uid(),
  enviado_em   timestamptz not null default now(),
  linhas       int,
  novas        int,
  alteradas    int,
  ignoradas    int,
  concluida    boolean not null default false
);

create table if not exists public.validador_nf_notas (
  chave              text primary key check (chave ~ '^[0-9A-Z]{44}$'),
  emitente           text,
  cnpj_emitente      text,
  uf_emitente        text,
  destinatario       text,
  cnpj_destinatario  text,
  uf_destinatario    text,
  manifesto          text,
  natureza           text,
  recebimento        date,
  emissao            date,
  numero_serie       text,
  valor              numeric,
  escrituracao       text,
  titulo             text,
  linha              int,                 -- linha no relatório em que apareceu por último
  primeira_carga     bigint references public.validador_nf_cargas(id),
  ultima_carga       bigint references public.validador_nf_cargas(id),  -- último relatório em que veio
  alterada_na_carga  bigint references public.validador_nf_cargas(id),  -- último relatório que mudou algum dado
  titulo_desde       timestamptz,          -- quando o título apareceu pela primeira vez
  atualizado_em      timestamptz not null default now()
);
create index if not exists validador_nf_notas_ultima_idx on public.validador_nf_notas (ultima_carga);
create index if not exists validador_nf_notas_emissao_idx on public.validador_nf_notas (emissao);

alter table public.validador_nf_cargas enable row level security;
alter table public.validador_nf_notas enable row level security;
drop policy if exists validador_nf_cargas_select on public.validador_nf_cargas;
create policy validador_nf_cargas_select on public.validador_nf_cargas for select to authenticated
  using ((select public.current_is_active()));
drop policy if exists validador_nf_notas_select on public.validador_nf_notas;
create policy validador_nf_notas_select on public.validador_nf_notas for select to authenticated
  using ((select public.current_is_active()));
-- sem políticas de insert/update/delete: só as funções abaixo gravam
revoke insert, update, delete on public.validador_nf_cargas, public.validador_nf_notas from anon, authenticated;
grant select on public.validador_nf_cargas, public.validador_nf_notas to authenticated;

create or replace function public.validador_pode_carregar()
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select public.current_is_active() and public."current_role"() in ('admin', 'supervisor');
$function$;

-- 1) abre uma carga
create or replace function public.validador_nf_iniciar_carga(p_arquivo text)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id bigint;
begin
  if not public.validador_pode_carregar() then
    raise exception 'Só administradores e supervisores podem atualizar a base do validador.' using errcode = '42501';
  end if;
  insert into validador_nf_cargas (arquivo, enviado_por) values (left(btrim(p_arquivo), 200), auth.uid())
  returning id into v_id;
  return v_id;
end;
$function$;

-- 2) grava um lote de linhas da carga (sem chave repetida dentro do mesmo lote)
create or replace function public.validador_nf_gravar_lote(p_carga bigint, p_linhas jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_res jsonb;
begin
  if not public.validador_pode_carregar() then
    raise exception 'Só administradores e supervisores podem atualizar a base do validador.' using errcode = '42501';
  end if;
  if not exists (select 1 from validador_nf_cargas c where c.id = p_carga and c.enviado_por = auth.uid() and not c.concluida) then
    raise exception 'Carga % não está aberta para este usuário.', p_carga;
  end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 5000 then
    raise exception 'Lote inválido (máximo de 5000 linhas por vez).';
  end if;

  with src as (
    select upper(regexp_replace(coalesce(x.chave, ''), '[^0-9A-Za-z]', '', 'g')) as chave,
           left(x.emitente, 300) as emitente, left(x.cnpj_emitente, 30) as cnpj_emitente, left(x.uf_emitente, 4) as uf_emitente,
           left(x.destinatario, 300) as destinatario, left(x.cnpj_destinatario, 30) as cnpj_destinatario, left(x.uf_destinatario, 4) as uf_destinatario,
           left(x.manifesto, 100) as manifesto, left(x.natureza, 300) as natureza,
           x.recebimento, x.emissao, left(x.numero_serie, 60) as numero_serie, x.valor,
           left(x.escrituracao, 100) as escrituracao, left(x.titulo, 60) as titulo, x.linha
    from jsonb_to_recordset(p_linhas) as x(chave text, emitente text, cnpj_emitente text, uf_emitente text,
         destinatario text, cnpj_destinatario text, uf_destinatario text, manifesto text, natureza text,
         recebimento date, emissao date, numero_serie text, valor numeric, escrituracao text, titulo text, linha int)
  ), ok as (
    select * from src where chave ~ '^[0-9A-Z]{44}$'
  ), up as (
    insert into validador_nf_notas as t (chave, emitente, cnpj_emitente, uf_emitente, destinatario, cnpj_destinatario,
           uf_destinatario, manifesto, natureza, recebimento, emissao, numero_serie, valor, escrituracao, titulo, linha,
           primeira_carga, ultima_carga, alterada_na_carga, titulo_desde, atualizado_em)
    select chave, emitente, cnpj_emitente, uf_emitente, destinatario, cnpj_destinatario, uf_destinatario, manifesto,
           natureza, recebimento, emissao, numero_serie, valor, escrituracao, titulo, linha,
           p_carga, p_carga, p_carga, case when coalesce(btrim(titulo), '') not in ('', '0') then now() end, now()
    from ok
    on conflict (chave) do update set
      emitente = excluded.emitente, cnpj_emitente = excluded.cnpj_emitente, uf_emitente = excluded.uf_emitente,
      destinatario = excluded.destinatario, cnpj_destinatario = excluded.cnpj_destinatario,
      uf_destinatario = excluded.uf_destinatario, manifesto = excluded.manifesto, natureza = excluded.natureza,
      recebimento = excluded.recebimento, emissao = excluded.emissao, numero_serie = excluded.numero_serie,
      valor = excluded.valor, escrituracao = excluded.escrituracao, titulo = excluded.titulo, linha = excluded.linha,
      ultima_carga = p_carga,
      alterada_na_carga = case when (t.emitente, t.cnpj_emitente, t.uf_emitente, t.destinatario, t.cnpj_destinatario,
            t.uf_destinatario, t.manifesto, t.natureza, t.recebimento, t.emissao, t.numero_serie, t.valor, t.escrituracao, t.titulo)
          is distinct from (excluded.emitente, excluded.cnpj_emitente, excluded.uf_emitente, excluded.destinatario,
            excluded.cnpj_destinatario, excluded.uf_destinatario, excluded.manifesto, excluded.natureza, excluded.recebimento,
            excluded.emissao, excluded.numero_serie, excluded.valor, excluded.escrituracao, excluded.titulo)
        then p_carga else t.alterada_na_carga end,
      titulo_desde = case
        when coalesce(btrim(excluded.titulo), '') in ('', '0') then null
        when coalesce(btrim(t.titulo), '') in ('', '0') then now()
        else t.titulo_desde end,
      atualizado_em = now()
    returning (xmax = 0) as nova, (t.alterada_na_carga = p_carga) as mudou
  )
  select jsonb_build_object(
    'novas', count(*) filter (where nova),
    'alteradas', count(*) filter (where not nova and mudou),
    'gravadas', count(*),
    'ignoradas', (select count(*) from src) - count(*))
  into v_res from up;
  return v_res;
end;
$function$;

-- 3) fecha a carga com o resumo
create or replace function public.validador_nf_concluir_carga(p_carga bigint, p_linhas int, p_novas int, p_alteradas int,
  p_ignoradas int, p_arquivo_path text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if not public.validador_pode_carregar() then
    raise exception 'Só administradores e supervisores podem atualizar a base do validador.' using errcode = '42501';
  end if;
  update validador_nf_cargas set linhas = p_linhas, novas = p_novas, alteradas = p_alteradas, ignoradas = p_ignoradas,
         arquivo_path = case when p_arquivo_path like 'carga_' || p_carga || '/%' then p_arquivo_path end, concluida = true
   where id = p_carga and enviado_por = auth.uid() and not concluida;
  if not found then raise exception 'Carga % não está aberta para este usuário.', p_carga; end if;
end;
$function$;

revoke all on function public.validador_pode_carregar() from public, anon;
revoke all on function public.validador_nf_iniciar_carga(text) from public, anon;
revoke all on function public.validador_nf_gravar_lote(bigint, jsonb) from public, anon;
revoke all on function public.validador_nf_concluir_carga(bigint, int, int, int, int, text) from public, anon;
grant execute on function public.validador_pode_carregar() to authenticated;
grant execute on function public.validador_nf_iniciar_carga(text) to authenticated;
grant execute on function public.validador_nf_gravar_lote(bigint, jsonb) to authenticated;
grant execute on function public.validador_nf_concluir_carga(bigint, int, int, int, int, text) to authenticated;

-- Arquivos originais (privado): todos os usuários ativos baixam; só admin/supervisor enviam, na pasta da carga
-- que eles mesmos abriram. Ninguém apaga nem substitui.
insert into storage.buckets (id, name, public, file_size_limit)
values ('validador-relatorios', 'validador-relatorios', false, 52428800)
on conflict (id) do nothing;

drop policy if exists validador_relatorios_select on storage.objects;
create policy validador_relatorios_select on storage.objects for select to authenticated
using (bucket_id = 'validador-relatorios' and (select public.current_is_active()));

drop policy if exists validador_relatorios_insert on storage.objects;
create policy validador_relatorios_insert on storage.objects for insert to authenticated
with check (bucket_id = 'validador-relatorios' and public.validador_pode_carregar()
  and exists (select 1 from public.validador_nf_cargas c
              where 'carga_' || c.id::text = split_part(storage.objects.name, '/', 1)
                and c.enviado_por = auth.uid() and not c.concluida));
