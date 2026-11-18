# Cópia de demonstração

Essa cópia tem um banco de dados **só dela**, e nada que você fizer aqui muda a barbearia de verdade. No topo aparece a faixa vermelha **DEMONSTRAÇÃO**.

1. **Supabase:** crie um projeto novo chamado `maycao-demo`, na região São Paulo.
2. **SQL Editor:** rode, nesta ordem e cada um numa consulta nova (+), os arquivos `schema.sql`, `mensalidade.sql`, `slot.sql` e `demo.sql`.
3. **Authentication → Users → Add user:** crie um login de teste, com **Auto Confirm**. Depois, no SQL Editor, rode:
   insert into public.contas (user_id, apelido) select id, 'Demo' from auth.users where email = 'EMAIL-DE-TESTE';
4. Desligue **Allow new users to sign up**.
5. Cole o **Project URL** e a **chave** desse projeto de teste no `config.js` desta pasta.
6. **GitHub:** suba a pasta `demo` inteira dentro do repositório `appmaycao`.
   - Site: `.../appmaycao/demo/`
   - App: `.../appmaycao/demo/app/`

**Logins da demonstração:**
- PIN da equipe: **Maycão 1234**, **Rafa 1111**, **Diego 2222**.
- Cliente: celular **(47) 99999-0000**, senha **1234**.

**Pra zerar a demonstração** depois de mexer: rode o `demo.sql` de novo.
