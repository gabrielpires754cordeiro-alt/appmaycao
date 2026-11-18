-- =====================================================================
--  Barbearia do Maycão — SLOT DE DESCONTO
--  Cole TUDO isto no Supabase: SQL Editor → New query → Run.
--  (Rode depois do schema.sql e do mensalidade.sql. Pode rodar de novo.)
--
--  Como funciona: quando um cliente agenda online (fora do plano), o banco
--  sorteia o resultado na hora. O app só mostra a animação. Assim ninguém
--  consegue trapacear mexendo no celular.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- sorteia e grava o resultado no próprio agendamento
create or replace function public._slot_sortear() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  cfg jsonb; m jsonb; it jsonb; itens jsonb; n int; r numeric; acc numeric := 0;
  ganhou jsonb; simb text[]; ult timestamptz; limite int; preco numeric; novo numeric; i int; a text; b text; c text;
begin
  if new.colecao <> 'appts' then return new; end if;
  if new.dados ? 'slot' then return new; end if;
  if coalesce(new.dados->>'origin','') <> 'online' then return new; end if;
  if coalesce((new.dados->>'plano')::boolean, false) then return new; end if;
  if exists (select 1 from public.registros x where x.colecao = new.colecao and x.id = new.id) then return new; end if;

  select dados->'slot' into cfg from public.config_publica where id = 1;
  if cfg is null or not coalesce((cfg->>'ativo')::boolean, false) then return new; end if;

  select mm into m from jsonb_array_elements(coalesce(cfg->'maquinas','[]'::jsonb)) mm
   where coalesce(mm->'servicos','[]'::jsonb) ? (new.dados->>'serviceId') limit 1;
  if m is null then return new; end if;
  itens := coalesce(m->'itens','[]'::jsonb);
  n := jsonb_array_length(itens);
  if n = 0 then return new; end if;

  -- limite: 1 giro a cada X dias por cliente
  limite := greatest(0, coalesce((cfg->>'limiteDias')::int, 7));
  select max((x.dados->'slot'->>'quando')::timestamptz) into ult from public.registros x
   where x.colecao = 'appts' and x.dados->>'clientId' = new.dados->>'clientId' and x.dados ? 'slot'
     and coalesce((x.dados->'slot'->>'bloqueado')::boolean, false) = false;
  if limite > 0 and ult is not null and ult > now() - make_interval(days => limite) then
    new.dados := new.dados || jsonb_build_object('slot', jsonb_build_object('bloqueado', true,
      'proximo', to_char((ult + make_interval(days => limite)) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'), 'maquina', m->>'nome'));
    return new;
  end if;

  -- sorteio (número aleatório seguro de 0 a 100)
  r := (('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000) / 10000.0;
  for it in select * from jsonb_array_elements(itens) loop
    acc := acc + greatest(0, coalesce((it->>'chance')::numeric, 0));
    if ganhou is null and r < acc then ganhou := it; end if;
  end loop;

  if ganhou is not null then
    simb := array[ganhou->>'icone', ganhou->>'icone', ganhou->>'icone'];
  else
    -- perdeu: três símbolos que NÃO são todos iguais
    i := floor(random() * n)::int; a := itens->i->>'icone';
    i := floor(random() * n)::int; b := itens->i->>'icone';
    loop
      i := floor(random() * n)::int; c := itens->i->>'icone';
      exit when n = 1 or not (a = b and b = c);
    end loop;
    if n = 1 then c := 'estrela'; end if;
    simb := array[a, b, c];
  end if;

  preco := coalesce((new.dados->>'price')::numeric, 0);
  novo := preco;
  if ganhou is not null and ganhou->>'tipo' = 'desconto' then
    novo := round(preco * (1 - least(100, greatest(0, coalesce((ganhou->>'valor')::numeric, 0))) / 100.0), 2);
  end if;

  new.dados := new.dados || jsonb_build_object(
    'price', novo,
    'slot', jsonb_build_object(
      'quando', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'maquina', m->>'nome',
      'simbolos', to_jsonb(simb),
      'ganhou', ganhou is not null,
      'tipo', ganhou->>'tipo',
      'valor', ganhou->'valor',
      'texto', ganhou->>'texto',
      'icone', ganhou->>'icone',
      'precoOriginal', preco));
  return new;
end $$;

drop trigger if exists slot_sortear on public.registros;
create trigger slot_sortear before insert on public.registros
  for each row execute function public._slot_sortear();

-- o cliente busca o resultado do agendamento que acabou de fazer (até 2 horas depois)
create or replace function public.resultado_slot(p_appt text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when r.dados ? 'slot' then (r.dados->'slot') || jsonb_build_object('price', r.dados->'price') else null end
    from public.registros r
   where r.colecao = 'appts' and r.id = p_appt and r.atualizado > now() - interval '2 hours'
     and coalesce(r.dados->>'origin','') = 'online';
$$;

revoke all on function public._slot_sortear() from public, anon, authenticated;
grant execute on function public.resultado_slot(text) to anon, authenticated;

-- configuração inicial (só se ainda não existir) — o Maycão edita tudo no app
update public.config_publica
   set dados = dados || jsonb_build_object('slot', '{
     "ativo": true,
     "limiteDias": 7,
     "maquinas": [
       {"id":"corte","nome":"Slot do Corte","servicos":["s1","s3","s7"],"itens":[
         {"id":"i1","icone":"cabelo","tipo":"desconto","valor":20,"chance":5},
         {"id":"i2","icone":"maquina","tipo":"desconto","valor":15,"chance":7},
         {"id":"i3","icone":"tesoura","tipo":"desconto","valor":10,"chance":10},
         {"id":"i4","icone":"secador","tipo":"desconto","valor":5,"chance":15},
         {"id":"i5","icone":"latinha","tipo":"brinde","texto":"Latinha de refrigerante","chance":10}]},
       {"id":"barba","nome":"Slot da Barba","servicos":["s2"],"itens":[
         {"id":"i6","icone":"barba","tipo":"desconto","valor":20,"chance":5},
         {"id":"i7","icone":"navalha","tipo":"desconto","valor":15,"chance":7},
         {"id":"i8","icone":"pente","tipo":"desconto","valor":10,"chance":10},
         {"id":"i9","icone":"secador","tipo":"desconto","valor":5,"chance":15},
         {"id":"i10","icone":"latinha","tipo":"brinde","texto":"Latinha de refrigerante","chance":10}]}
     ]}'::jsonb)
 where id = 1 and not (dados ? 'slot');
