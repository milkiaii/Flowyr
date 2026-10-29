# Flowyr para macOS

Flowyr é um fork experimental do Vita3K para
iOS e macOS. Agradecemos ao time original do Vita3K e aos colaboradores.

```sh
./build-macos.sh          # dist/macos/Flowyr.app e Flowyr.zip
./build-macos.sh --clean
```

O nome no Finder, Dock, menus e janelas é Flowyr. O ícone é gerado do `logo.png`
da raiz. Os créditos e links do Vita3K original permanecem identificados como
recursos do projeto original; a atualização automática pelo upstream está desativada.

## Saves no iCloud

Abra **Settings/Configurações → Saves no iCloud** e ative **Sincronizar todos os
saves**. Use a mesma conta do iCloud com iCloud Drive ativo no Mac e no iPhone/iPad;
ative a opção correspondente em **Opções → Saves no iCloud** no iOS.

A sincronização é feita ao voltar ao app, receber alterações do iCloud e encerrar
um jogo. **Sincronizar agora** permite solicitar uma verificação. Feche jogos e
outras janelas de configuração antes de sincronizar e espere a confirmação do
envio antes de trocar de aparelho. O encerramento do app aguarda a operação local
em andamento; o envio pendente continua sob responsabilidade do iCloud.

Todos os usuários e jogos são incluídos, inclusive jogos não instalados no outro
aparelho. O identificador de usuário (por exemplo, `00`) é mantido entre aparelhos.
O Mac usa `ux0/user/<usuário>/savedata` na pasta de armazenamento configurada;
o iOS usa `Documents/vita/ux0/user/<usuário>/savedata`. Não é necessário mover saves.

Os dois apps usam os mesmos documentos `.vitasave` em **iCloud Drive → Flowyr → Saves**.
Progresso divergente exige escolher a versão do Mac ou do iCloud. As revisões
anteriores permanecem no iCloud, e saves locais substituídos são guardados em
`Save Backups` na raiz de armazenamento. Desativar a opção não apaga saves nem cópias.
É possível jogar offline; uma mensagem de envio pendente não significa perda do save.

Atualize o Flowyr nos dois aparelhos. Cópias da primeira implementação de iCloud
podem conter caminhos incorretos; esta versão preserva essas cópias como histórico
e impede sua restauração. Sincronize primeiro no aparelho que contém os saves
originais: ele publica automaticamente revisões no formato corrigido, sem apagar
o histórico. Se houver conflito, escolha o save local desse aparelho.

## Assinatura e dados existentes

O build usa Apple Development e provisioning automático do Xcode. O app para Mac
agora compartilha o App ID registrado `dev.vita3k.Vita3KIos` e o container
`iCloud.dev.vita3k.Vita3KIos` com o iOS. O perfil **nativo de macOS** autoriza
o acesso; copiar apenas entitlements sem o perfil não habilita o iCloud.
O pacote de desenvolvimento requer um Mac autorizado no perfil.

As pastas e configurações do desktop continuam no local anterior
(`~/Library/Application Support/Vita3K/Vita3K/`, ou a pasta personalizada/portátil).
O bundle do iOS permanece igual. O pequeno target `signing/` apenas obtém o perfil;
o executável distribuído continua sendo o emulador compilado pelo CMake.

## Testes

```sh
macos/test-save-sync.sh
```

Executa a suíte compartilhada de saves em diretórios temporários: transferência
Mac/iOS, backup, conflitos offline, conta, arquivos inseguros e bloqueio durante
uso da biblioteca. Esses testes não escrevem saves na conta real do iCloud.
Compatibilidade e desempenho de jogos no macOS continuam experimentais.
