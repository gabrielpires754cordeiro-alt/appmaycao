# Barbearia do Maycão — site + app Maycão Gestão

Esta pasta tem tudo para colocar no ar:

| O que | Arquivo | Endereço depois de publicado |
|---|---|---|
| **Site** da barbearia | `index.html` | `https://SEU-USUARIO.github.io/barbearia-do-maycao/` |
| **App Maycão Gestão** (agenda, clientes, financeiro, estoque, ajustes) | `app/` | `https://SEU-USUARIO.github.io/barbearia-do-maycao/app/` |
| Ligação com o banco de dados | `config.js` | — |
| Banco de dados (Supabase) | `supabase/schema.sql` | — |

O site e o app usam o **mesmo banco de dados (Supabase)**. Tudo o que o Maycão muda no app (preços, serviços, horários, equipe, contato e textos) aparece sozinho no site. Quando o cliente agenda pelo site, o horário cai na hora na agenda do barbeiro.

---

## Passo 1 — Criar o banco de dados (Supabase, grátis)

1. Entre em **supabase.com** e crie uma conta. O ideal é usar o e-mail do Maycão, porque o banco fica sendo dele.
2. Clique em **New project**:
   - Nome: `barbearia-do-maycao`
   - Database password: crie uma senha forte e **guarde** (você quase nunca vai usar)
   - Region: **South America (São Paulo)**
3. Espere uns 2 minutos até o projeto ficar pronto.
4. No menu da esquerda, abra **SQL Editor** → **New query**. Abra o arquivo `supabase/schema.sql`, copie **tudo**, cole e clique em **Run**. Tem que aparecer "Success".

## Passo 2 — Criar o login da barbearia

O app pede um e-mail e uma senha **uma vez em cada aparelho**. Depois disso, cada pessoa entra só com o PIN dela.

1. No Supabase, abra **Authentication** → **Users** → **Add user** → **Create new user**.
   - E-mail: o da barbearia (ex.: o e-mail do Maycão)
   - Senha: uma senha forte
   - Marque **Auto Confirm User**
2. Volte no **SQL Editor**, cole isto (trocando o e-mail) e clique em **Run**:

   ```sql
   insert into public.contas (user_id, apelido)
   select id, 'Barbearia' from auth.users where email = 'EMAIL-DA-BARBEARIA@gmail.com';
   ```

3. **Muito importante:** desligue os cadastros novos para ninguém criar conta sozinho. Vá em **Authentication** → **Sign In / Providers** (ou **Settings**) e **desative** a opção **Allow new users to sign up**.

## Passo 3 — Ligar o site e o app ao banco

1. No Supabase, abra **Project Settings** → **API** (ou **Data API / API Keys**).
2. Copie o **Project URL** e a chave **anon public**.
3. Abra o arquivo `config.js` no Bloco de Notas e cole os dois:

   ```js
   window.MAYCAO_CONFIG = {
     SUPABASE_URL: 'https://xxxxxxxx.supabase.co',
     SUPABASE_ANON_KEY: 'eyJhbGciOi...'
   };
   ```

   A chave **anon** pode ficar pública, porque quem protege os dados são as regras do banco. **Nunca** coloque a chave **service_role** nesse arquivo.

## Passo 4 — Publicar no GitHub (grátis)

1. Entre em **github.com** e crie um repositório **público** chamado `barbearia-do-maycao`.
2. Clique em **uploading an existing file** e **arraste todo o conteúdo desta pasta**: `index.html`, `config.js`, `logo.webp`, `.nojekyll` e as pastas `app` e `supabase`. Depois clique em **Commit changes**.
   - No Windows, o arquivo `.nojekyll` pode ficar escondido. Ele não é obrigatório.
3. Vá em **Settings** → **Pages** → em *Branch*, escolha **main** e **/ (root)** → **Save**.
4. Em 1 ou 2 minutos aparecem os endereços:
   - Site: `https://SEU-USUARIO.github.io/barbearia-do-maycao/`
   - App: `https://SEU-USUARIO.github.io/barbearia-do-maycao/app/`

> Para mudar algo no código depois, é só subir o arquivo de novo no GitHub. Preço, horário e texto **não** precisam disso: o Maycão muda pelo app.

## Passo 5 — Primeiro acesso do Maycão

1. Abra o **app** e entre com o e-mail e a senha do Passo 2.
2. Toque em **Maycão** e digite o PIN **123**. O app vai pedir para ele criar o PIN dele, de 4 a 6 números.
3. Na aba **Ajustes**:
   - Confira os **preços** (estão os que combinamos; o Corte está R$ 60).
   - Adicione os **barbeiros** em **+ Barbeiro**. Cada um entra no primeiro acesso com o PIN **123** e cria o dele.
   - Confira **contato e textos do site**: frase do topo, "Quem somos", nota no Google, clientes atendidos e ano de abertura.
   - Ajuste o **horário de funcionamento**.

## Passo 6 — Instalar o app no celular

- **Android (Chrome):** abra o endereço do app → menu **⋮** → **Instalar app** (ou **Adicionar à tela inicial**). Também pode aparecer o botão **📲 Instalar o app** na tela de entrada.
- **iPhone (Safari):** abra o endereço do app → botão **Compartilhar** → **Adicionar à Tela de Início**.
- **Computador (Chrome/Edge):** ícone de instalar na barra de endereço.

O app fica com o ícone da barbearia, abre em tela cheia e funciona mesmo com internet fraca. O que for feito sem internet fica salvo no aparelho e sobe quando a conexão voltar.

---

## Como fica a segurança

| Quem | O que consegue |
|---|---|
| **Cliente** (sem login) | Ver o site e agendar. Não vê o nome nem o telefone de ninguém, só os horários livres. |
| **Barbeiro** (PIN dele) | A própria agenda e os próprios ganhos. |
| **Maycão** (PIN dele) | Tudo, e é o **único** que muda preços, serviços, horários, equipe e textos do site. O banco confere o PIN dele em cada alteração. |
| **Alguém de fora** com outro e-mail | Nada. |

Ainda tem mais duas proteções:
- Depois de **8 PINs errados** seguidos, aquela pessoa fica bloqueada por 10 minutos.
- O banco não deixa marcar dois clientes no mesmo horário com o mesmo barbeiro, nem horário fora do expediente.

## Problemas comuns

**O app mostra "FALTA CONFIGURAR".** O `config.js` ainda está com `COLE_AQUI`. Refaça o Passo 3 e suba o `config.js` de novo no GitHub.

**"Esse e-mail não é da barbearia".** Falta o comando do Passo 2, item 2 (o `insert into public.contas`).

**Um barbeiro esqueceu o PIN.** O Maycão vai em **Ajustes → Editar** o barbeiro → **Resetar para 123**.

**O Maycão esqueceu o PIN dele.** No Supabase, abra **SQL Editor** e rode:

```sql
update public.pins set hash = extensions.crypt('123', extensions.gen_salt('bf', 8)),
  troca_obrigatoria = true, falhas = 0, bloqueado_ate = null
where barber_id = 'b1';
```

Depois ele entra com **123** e cria um novo.

**O site mostra preços antigos.** Recarregue a página. O site lê o banco quando abre e se atualiza sozinho a cada 2 minutos.

**O projeto do Supabase "pausou".** No plano grátis, o projeto pode pausar se ficar uma semana sem nenhum uso. Com agendamentos todo dia isso não acontece. Se acontecer, é só entrar no supabase.com e clicar em **Restore**.

## Domínio próprio (opcional)

Para ter um endereço como `barbeariadomaycao.com.br`:
1. Registre o domínio no **registro.br** (por volta de R$ 40 por ano).
2. No GitHub, em **Settings** → **Pages** → **Custom domain**, coloque o domínio.
3. No registro.br, aponte o DNS conforme as instruções do GitHub Pages.

## Entrega para o Maycão

- Crie o Supabase e o GitHub **no e-mail dele**, ou transfira depois. No GitHub é em **Settings → Transfer ownership**; no Supabase, convide o e-mail dele na organização como **Owner**.
- Entregue a ele o e-mail e a senha do login da barbearia.
