-- 🏢 Padrão do destinatário: o nome da empresa destinatária passa a vir do CNPJ, sempre com a mesma grafia.
-- Antes era texto livre e o mesmo CNPJ aparecia como "CONSORCIO VIAS CAPIXABA", "Consorcio Vias Capixaba",
-- "CONSORCIO VIAS CAPIXABAS (0097"... ou em branco.
create table if not exists public.empresas (
  cnpj text primary key check (cnpj ~ '^\d{14}$'),  -- só dígitos
  razao_social text not null check (btrim(razao_social) <> ''),
  created_at timestamptz not null default now()
);
alter table public.empresas enable row level security;
drop policy if exists empresas_select on public.empresas;
create policy empresas_select on public.empresas for select using (public.current_is_active());
drop policy if exists empresas_write on public.empresas;
create policy empresas_write on public.empresas for all
  using (public.current_is_active() and public."current_role"() = 'admin')
  with check (public.current_is_active() and public."current_role"() = 'admin');
grant select on public.empresas to authenticated;
grant insert, update, delete on public.empresas to authenticated;

insert into public.empresas (cnpj, razao_social) values
  ('04101986000147', 'AMETA ENGENHARIA LTDA'),
  ('38006053000192', 'RAF INFRAESTRUTURA LTDA'),
  ('54344984000157', 'CONSORCIO AMETA-OCC'),
  ('66650954000158', 'CONSORCIO VIAS CAPIXABA')
on conflict (cnpj) do nothing;

-- Ao gravar uma nota (cadastro, edição, SIENGE, estoque): se o CNPJ destinatário é de uma empresa cadastrada,
-- o destinatário recebe a razão social padrão. Na edição só age quando CNPJ ou destinatário mudam — assim
-- não interfere em outras atualizações da nota (ex.: marcar atribuição como vista).
create or replace function public.notas_destinatario_padrao()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nome text;
begin
  if tg_op = 'UPDATE'
     and new.cnpj_destinatario is not distinct from old.cnpj_destinatario
     and new.destinatario is not distinct from old.destinatario then
    return new;
  end if;
  select e.razao_social into v_nome from public.empresas e
   where e.cnpj = regexp_replace(coalesce(new.cnpj_destinatario, ''), '\D', '', 'g');
  if v_nome is not null then
    new.destinatario := v_nome;
  end if;
  return new;
end;
$function$;
drop trigger if exists notas_destinatario_padrao_trg on public.notas;
revoke execute on function public.notas_destinatario_padrao() from public, anon;
create trigger notas_destinatario_padrao_trg before insert or update on public.notas
  for each row execute function public.notas_destinatario_padrao();

-- Padroniza as notas já cadastradas. Ficam de fora as que têm CNPJ destinatário diferente dos CNPJs da obra:
-- nelas não dá para saber se o errado é o CNPJ ou a obra, e o usuário confirma ao editar.
do $$
begin
  perform set_config('app.integracao', 'true', true);
  update public.notas n
     set destinatario = e.razao_social
    from public.empresas e
   where e.cnpj = regexp_replace(coalesce(n.cnpj_destinatario, ''), '\D', '', 'g')
     and n.destinatario is distinct from e.razao_social
     and (
       n.obra_id is null
       or not exists (select 1 from public.obra_cnpjs oc where oc.obra_id = n.obra_id)
       or exists (select 1 from public.obra_cnpjs oc where oc.obra_id = n.obra_id
                   and regexp_replace(oc.cnpj, '\D', '', 'g') = e.cnpj)
     );
end $$;
