-- 🏢 Razão social padrão dos consórcios que faltavam na tabela empresas (informada pela empresa em 09/10/2026).
insert into public.empresas (cnpj, razao_social) values
  ('67546476000101', 'CONSÓRCIO AC MARAJÓ'),
  ('65862352000100', 'CONSÓRCIO VIAS GUAJARÁ'),
  ('66603136000102', 'CONSÓRCIO ATL XINGU'),
  ('66026460000105', 'CONSÓRCIO INFRAVIAS'),
  ('57080615000192', 'CONSÓRCIO MAGUARI')
on conflict (cnpj) do nothing;
