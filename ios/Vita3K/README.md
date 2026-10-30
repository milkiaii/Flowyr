# Flowyr para iOS

**Flowyr** é um **fork experimental
do [Vita3K](https://github.com/Vita3K/Vita3K) para iOS**, mantido separadamente do
projeto original. Agradecemos ao time original do **Vita3K** e a todos os seus
colaboradores pelo emulador, pela pesquisa e pelo trabalho que tornam este fork
possível. A licença GPLv2 e os avisos de copyright originais são preservados.

**iOS é o alvo principal; macOS tem suporte experimental**, incluindo sincronização
de saves com o iOS pelo iCloud. Veja o [guia para macOS](../../macos/README.md).
O código para **Windows e Linux** continua presente, mas essas versões **não são
suportadas nem testadas**. Android também está fora do escopo deste fork.
Compatibilidade e desempenho do Vita3K original não garantem os mesmos resultados.

O nome apresentado no app, na tela de Início e no Arquivos é **Flowyr**.
O bundle é `dev.vita3k.Flowyr` (container iCloud `iCloud.dev.vita3k.Flowyr`).
Como o identificador mudou, o app é instalado separado de versões anteriores e
não herda jogos, saves ou configurações delas. Os nomes internos
(`ios/Vita3K`, targets, módulos e scripts) são mantidos.

Para investigar jogos com crashes, stucks, slowdown ou glitches, veja
[modos de diagnóstico e skills](DIAGNOSTICS.md).

Frontend SwiftUI/UIKit para o core Vita3K cross-compilado (ver `ios-plan.md`).
Biblioteca com ícones locais, busca, favoritos, grade/lista e último jogo;
opções e diagnóstico separados, com suporte a retrato e paisagem.

### Idioma da interface

A interface iOS abre em **inglês** por padrão, independentemente do idioma do
aparelho. Em **Settings → Language → Interface language**, escolha **English**
ou **Português (Brasil)**. A alteração é imediata e persiste entre aberturas;
não altera o idioma emulado dos jogos.

As traduções ficam em `App/Resources/en.lproj` e `App/Resources/pt-BR.lproj`.
As frases originais são chaves estáveis de `Localizable.strings`; contagens
usam `Localizable.stringsdict`. Para adicionar um idioma, inclua os dois
arquivos em uma nova pasta `<idioma>.lproj` e registre-o em `AppLanguage`.
SwiftUI usa o locale da interface, enquanto UIKit e mensagens do app usam
`L10n`. Textos fornecidos por jogos, relatórios brutos do core e componentes
do sistema mantêm sua própria origem/idioma.

`LocalizationTests` verifica recursos, preferência, plurais e mensagens;
`LocalizationInterfaceTests` verifica troca imediata e persistência no simulador.

## Duas flavors

| Flavor    | Projecto        | MoltenVK                     |
| --------- | --------------- | ---------------------------- |
| device    | `project.yml`   | sim (slice estático `ios-arm64` do XCFramework v1.4.1) |
| simulator | `project-sim.yml` | sim (biblioteca estática compilada da fonte; ver `scripts/build-moltenvk-sim.sh`) |

O core é gerado pelo CMake; este projeto Xcode é **gerado** pelo XcodeGen a
partir do `project.yml`/`project-sim.yml` e **não deve ser editado à mão**
(`Vita3K.xcodeproj` é descartável).

## Fluxo de build

Para gerar o app e o IPA assinados com o certificado e o Team ID disponíveis
na máquina, execute na raiz do repositório:

```sh
./build-ios.sh          # saída: dist/ios/Flowyr.app e dist/ios/Flowyr.ipa
./build-ios.sh --clean  # limpa os intermediários de iOS antes de recompilar
```

O script usa o logo atual, compila o core, faz staging, gera o projeto e assina
o app e a biblioteca com a mesma identidade. O IPA usa assinatura de
desenvolvimento e exige um aparelho autorizado pelo provisioning profile.
Dependências e opções de certificado/equipe estão no
[guia de build](../../building.md#local-signed-apple-builds).
O fluxo manual equivalente continua abaixo.

Os presets `ios-device` e `ios-simulator` compilam o núcleo em **Release**:
`-O3`, `NDEBUG` e ThinLTO nos componentes C/C++; os arquivos Objective-C/Objective-C++
também usam `-O3`, mas não recebem IPO do CMake. O app usa Swift `-O` e
Whole Module Optimization; o projeto Xcode habilita ThinLTO para código Clang.
O Run do projeto gerado também usa Release. Os modos de diagnóstico continuam disponíveis nessa build; não
dependem da instrumentação Tracy das builds Debug/RelWithDebInfo.

O link do núcleo grava `libVita3KCore.dylib.build-config` junto do binário.
O staging copia ambos, e o Xcode rejeita um app Release que tente incorporar
um núcleo Debug/RelWithDebInfo. Apenas mudar `CMakeCache.txt` ou o esquema do
Xcode não substitui a recompilação do núcleo.

```sh
# 1) Build o core para a flavor escolhida (device ou simulator)
cmake --preset ios-device        # ou ios-simulator
cmake --build --preset ios-device

# 2) Stage o core em Vendor/ e (re)gera o projeto Xcode
ios/Vita3K/scripts/stage-core.sh device    # ou: ... simulator

# 3a) Via Xcode (device físico):
open ios/Vita3K/Vita3K.xcodeproj
# escolha a flavor adequada ao projeto gerado, selecione o iPhone e Run.

# 3b) Via CLI (simulador):
xcodebuild -project ios/Vita3K/Vita3K.xcodeproj -scheme Vita3K \
    -configuration Release -destination "platform=iOS Simulator,name=iPhone 17" build
xcrun simctl install <udid> <Vita3K.app em DerivedData>
xcrun simctl launch <udid> dev.vita3k.Flowyr
```

Sempre que o core mudar, repita 1–2 (o `stage-core.sh` copiar o novo
`libVita3KCore.dylib` para `Vendor/` e regenera o projeto).

### Importação de jogos

O seletor de arquivos, a inicialização e a pasta `imports/` compartilham o
histórico persistente `.imports-state.json`. Conteúdo importado com sucesso
não é reinstalado ao reabrir o app. Marcadores antigos `.imports-done`,
`.imports-failed` e `.fw-done` continuam sendo respeitados. Uma importação
automática de ZIP/VPK/pasta também preserva um jogo já instalado pelo
`TITLE_ID`, independentemente do nome do arquivo de origem.

Ao terminar cada tentativa, com sucesso ou falha, o arquivo ou pasta de origem
em `imports/` é apagado em segundo plano. O resultado e eventuais erros continuam
na tela e no histórico. O original selecionado fora de `imports/` é preservado.
Para tentar novamente, selecione o original pelo botão **Importar** ou copie-o
novamente para `imports/`, inclusive com o mesmo nome. Se o processo terminar durante uma instalação, o app
informa a interrupção na próxima abertura, sem iniciar outra tentativa.

A cópia do seletor ocorre em segundo plano com acesso coordenado ao arquivo.
ZIP/VPK é extraído diretamente para disco, com validação de CRC e tamanho,
sem carregar todo o jogo na RAM. A instalação de pastas/arquivos extraídos
é preparada separadamente antes de substituir a cópia existente; erros de
cópia, metadados ou decriptação preservam o jogo anterior.

Regressão de ZIP/SFO com ASan/UBSan: `bash ios/Vita3K/scripts/test-imports.sh`.
O conjunto `Vita3KInputTests/ImportTests` verifica persistência, falhas,
reabertura, cópia do seletor e preservação de jogos existentes no simulador.

### Resolução interna e saída para a tela

A resolução interna por jogo entra em vigor ao reiniciar o título. `2x`
dobra a largura e a altura dos alvos de renderização. A superfície Metal usa
a densidade de pixels da tela, independentemente desse multiplicador; uma
saída limitada a pontos do UIKit descartava detalhe mesmo com upscale interno.
Em modo Graphics, `draw_sample` registra o multiplicador efetivo e
`startup-probe.txt` registra pontos, escala e tamanho em pixels da superfície.
Texturas, menus pré-renderizados e vídeos não ganham detalhe novo apenas
com esse ajuste.

### Teclado em jogos

Pedidos de texto via `sceImeOpen` e `sceImeDialogInit` abrem automaticamente
o teclado nativo do iPhone. O campo preserva o texto inicial e o cursor;
permite seleção, colagem, edição no meio do texto e composição pelo UIKit.
O limite do jogo é respeitado em unidades UTF-16, sem cortar caracteres.

**OK** (ou Concluído no teclado, para campos de uma linha) envia o texto e
confirma o pedido para o jogo. **Cancelar** aparece apenas quando permitido.
Nos diálogos, a confirmação preenche o buffer de resultado e finaliza o
diálogo; no IME de baixo nível, envia os eventos Enter/Close. Os controles
virtuais ficam ocultos enquanto o teclado está aberto. Encerrar a sessão
fecha o teclado sem confirmar um nome por acidente.

Cada pedido tem um identificador: campos consecutivos recebem seu próprio
texto inicial e não aceitam ações atrasadas de um campo anterior. O teclado
funciona com os logs desativados.

Regressão do core sem firmware/JIT: `ios/Vita3K/scripts/test-ime-core.sh`
(AddressSanitizer + UndefinedBehaviorSanitizer). `GameKeyboardTests` no target
`Vita3KInputTests` cobre edição UIKit, composição, limites, foco e fechamento.

### Troca de aplicativo

Ao perder o foco, a sessão em memória é pausada. CPU e áudio param; o
renderizador termina as submissões em andamento, aguarda a GPU e bloqueia
novos frames antes de o app entrar em segundo plano. Ao voltar, a mesma
sessão continua, mantendo a pausa do menu HOME e o campo de texto aberto.
Entradas pressionadas são liberadas para evitar botões presos.

A transição também cobre carregamento e demo Vulkan. O JIT é verificado
antes da retomada; se tiver sido revogado, a sessão permanece suspensa e a
UI orienta a reabrir pelo StikDebug. Encerrar o processo (inclusive pelo
iOS) ainda exige iniciar o jogo novamente; não há save states nesta entrega.

Regressão da sincronização GPU: `bash ios/Vita3K/scripts/test-render-gate.sh`
(ASan/UBSan). `InterfaceTests.testBackgroundRetainsGameAndUserPause` alterna
entre Flowyr e Ajustes, compara a geração da sessão e o contador de frames,
verifica a pausa HOME e encerra a sessão.

### Regressão de texturas PVRTC

`ios/Vita3K/scripts/test-pvrt-upload.sh` verifica a preparação real das texturas
PVRTC1/II a 2/4bpp até o upload RGBA8, com ASan/UBSan: cores conhecidas, mips,
cubemaps e dimensões arbitrárias. Roda no Mac sem GPU, firmware ou JIT; requer
FFmpeg de desenvolvimento acessível pelo `pkg-config` (`libswscale`/`libavutil`).
A confirmação visual de um jogo continua dependendo do teste no iPhone.

### Triangle fans no Metal

No backend Vulkan da Apple, fans com 3–4096 índices e memory mapping
desativado são convertidos na CPU para listas de triângulos antes do upload.
Isso evita a conversão por compute do MoltenVK e as interrupções de render
pass por draw observadas no perfil do Muramasa Rebirth. A conversão preserva
winding, vértice de flat shading, índices U16/U32 e instâncias; não modifica
resolução, shaders ou pacing do jogo. Fans maiores e índices mapeados continuam
no caminho do driver, pois podem depender de escritas da GPU.

Regressão de geometria com ASan/UBSan, sem GPU/firmware/JIT:
`ios/Vita3K/scripts/test-triangle-fan.sh`.
A/B de FPS e confirmação visual devem usar o mesmo trecho no aparelho.

### Correções portadas do Vita3K-Plus (2026-09-30)

Integração seletiva da branch
[`all-enhancements` de nckstwrt/Vita3K-Plus](https://github.com/nckstwrt/Vita3K-Plus/tree/e2331f809a50f093ca1e2920e47e7dba67d08f3d),
revisão `e2331f809a50f093ca1e2920e47e7dba67d08f3d`. O histórico deste fork
foi importado originalmente sem ancestralidade Git compartilhada; a comparação
de código usou também a base do Plus `5b040dc4a`. Créditos a nckstwrt e aos
autores originais, mantendo a licença GPL. A tabela descreve as correções de
código incorporadas; **não certifica esses jogos como testados no iPhone**.

| Jogo / área | Mudança incorporada | Commit de referência no Plus |
| --- | --- | --- |
| Jet Set Radio | Abrir eventos pelo nome, remover o evento do mapa correto e swizzle U1U5U5U5 em Vulkan | [`987bfea47`](https://github.com/nckstwrt/Vita3K-Plus/commit/987bfea47) |
| Injustice | Inicialização, leitura e escrita do clip da superfície de cor | [`f23e32346`](https://github.com/nckstwrt/Vita3K-Plus/commit/f23e32346) |
| Dragon Quest Heroes II | Inicializar dados de processo, estado e CPU em GetThreadInfo | [`601374c61`](https://github.com/nckstwrt/Vita3K-Plus/commit/601374c61) |
| Demon Gaze | Timeout na espera de término de thread; manter FINISHED consultável no diálogo de save | [`316f1c914`](https://github.com/nckstwrt/Vita3K-Plus/commit/316f1c914) |
| Disgaea 3 / Madden 13 | Fechamento assíncrono do diálogo de save; implementação limitada de localização para Disgaea | [`d5ac2d6f1`](https://github.com/nckstwrt/Vita3K-Plus/commit/d5ac2d6f1), [`64be7ddf1`](https://github.com/nckstwrt/Vita3K-Plus/commit/64be7ddf1), [`7451f9f4b`](https://github.com/nckstwrt/Vita3K-Plus/commit/7451f9f4b) |
| Borderlands 2 | Responder à tentativa de matchmaking offline por callback, sem aguardar PSN indefinidamente | [`937f75719`](https://github.com/nckstwrt/Vita3K-Plus/commit/937f75719) |
| Ys: Memories of Celcetta | Indexar uma vez cada árvore de arquivos na busca sem distinção de maiúsculas/minúsculas | [`7e6e22a4d`](https://github.com/nckstwrt/Vita3K-Plus/commit/7e6e22a4d) |
| Shin Gundam Musou | AAC/SBR respeita frequência e canais pedidos pelo guest; compressor NGS processa o áudio | [`997654b3f`](https://github.com/nckstwrt/Vita3K-Plus/commit/997654b3f) e implementação acumulada do compressor |
| Shantae | Seguir buffers vazios até o próximo trecho PCM, com limite para ciclos vazios | [`121ad4eae`](https://github.com/nckstwrt/Vita3K-Plus/commit/121ad4eae) |
| ATRAC9 / PCSG00841 | Decodificação parcial escreve no início do buffer de destino, usando o offset apenas na origem | [`e2331f809`](https://github.com/nckstwrt/Vita3K-Plus/commit/e2331f809) |
| UPPERS | Tamanho declarado dos temporários e repetição de IMAD32 | [`706ae33ee`](https://github.com/nckstwrt/Vita3K-Plus/commit/706ae33ee) |
| Madden 13 / FIFA 15 | Repetição de IMAD8/16, escala de indexação bitwise e subtração de src2 em IMAD16 | [`d74b53c77`](https://github.com/nckstwrt/Vita3K-Plus/commit/d74b53c77), [`0426045fa`](https://github.com/nckstwrt/Vita3K-Plus/commit/0426045fa), [`42edce319`](https://github.com/nckstwrt/Vita3K-Plus/commit/42edce319) |
| Ultimate Marvel vs. Capcom 3 | Aplicar offsets SMLSI/SMBO em VNMAD | [`099eb7157`](https://github.com/nckstwrt/Vita3K-Plus/commit/099eb7157) |
| Gundam Breaker 3 | Predicados curtos de VMAD2 e máscara esparsa de SOP2M | [`b87189eb4`](https://github.com/nckstwrt/Vita3K-Plus/commit/b87189eb4) |
| Super Hero Nation | Máscaras de bits de VTSTMSK e teste do bit de sinal em resultados inteiros de 32 bits | [`dec3399ad`](https://github.com/nckstwrt/Vita3K-Plus/commit/dec3399ad) |
| Epic Mickey 2 | Repetição interna não avança operandos externos | [`d2cadf359`](https://github.com/nckstwrt/Vita3K-Plus/commit/d2cadf359) |
| MotoGP 14 | Saturar conversão F16 em ±65504 preservando NaN | [`105331d90`](https://github.com/nckstwrt/Vita3K-Plus/commit/105331d90) |
| Soul Sacrifice Delta | Corrigir a escala e os offsets da profundidade usada pelo outline, considerando a grade MSAA realmente armazenada e o último tile parcial | [`d248beeed`](https://github.com/nckstwrt/Vita3K-Plus/commit/d248beeed), ajuste de dimensões de [`adb22ff1f`](https://github.com/nckstwrt/Vita3K-Plus/commit/adb22ff1f) e alinhamento de [`98a65bff2`](https://github.com/nckstwrt/Vita3K-Plus/commit/98a65bff2) |

Também foram incorporados NEGP2 sem mudar a codificação de PN e o conserto
de branches incondicionais do analisador de shaders (`8b051123b`, `7451f9f4b`,
`9ed7effa5`). A versão do cache de shaders/pipelines passou de 18 para 19,
para que o código recompilado use as correções automaticamente.

Adaptações locais: registro de `SceLibLocation` na inicialização, limpeza de
callbacks de matchmaking entre sessões, timeout usando a condição de thread
existente, proteção contra espera da própria thread, mutex no índice de
arquivos e limite de navegação em cadeias de áudio. Permanecem as correções
locais de Ys VIII, os workarounds opt-in de Killzone/Resistance, JIT, controles,
teclado e sincronização GPU no iOS.

Esta integração não inclui a reescrita do scheduler/memory mapping, os hacks
que forçam desbloqueio de threads ou encerram streams por silêncio, patches
binários de libfios2/AvPlayer, alterações de UI/branding/Android nem a
reestruturação extensa do cache de superfícies do Plus. As correções que
dependem desses caminhos (por exemplo, cubemaps de Ridge Racer, superfícies
de outros jogos e snapshots de vértices de Skullgirls) continuam
pendentes de uma adaptação e validação específicas no Metal/iOS.

Regressões de host, sem jogos/firmware/JIT:

```sh
cmake --build build/macos-ninja --config Release --target shader-tests game-compatibility-tests
ctest --test-dir build/macos-ninja -C Release -R '^(shader|game-compatibility)$' --output-on-failure
```

Os testes exercitam instruções reais pelo decoder USSE, APIs HLE, transições
de save/thread, cache de arquivos, cadeias PCM, compressor e conversão AAC
com sentinelas no buffer. Compilação do core verificada em `ios-device` e
`ios-simulator`; a confirmação visual/sonora e de progressão depende do reteste
de cada jogo no aparelho.

A espera de condição mantém o timeout restante ao readquirir o mutex. Isso
evita que o carregamento de Ys VIII bloqueie a `DrawThread` indefinidamente
quando a thread de carregamento sinaliza `DrawSignal` mantendo o mutex.
`game-compatibility-tests` cobre essa disputa com mutexes leves e normais,
além da recuperação de um mutex disponível após a expiração do prazo.

O cache de shaders rejeita arquivos sem índice completo de versão/recursos
da GPU. As variantes de formato de saída usam a mesma identidade em disco,
na compilação e no pré-carregamento; o cache v20 substitui os arquivos v19.
`renderer-shader-cache-tests` cobre índices ausentes/truncados, troca de
recursos e compilação fria/quente de formatos de saída distintos. A correção
foi motivada por shaders de Ys VIII que ainda exigiam texture viewport no
modo High, que não envia esses parâmetros. Em 01/10/2026, o usuário confirmou
que Ys VIII (PCSE01103 1.00) voltou a funcionar após o loading no iPhone, com
a versão 0.2.1-14, modo High e resolução 2x. A regressão de tela preta na
inicialização está resolvida; evidências no caso `ys8-cache-fixed-20261001`.

O outline de Soul Sacrifice Delta recebeu uma adaptação separada do cache
Vulkan, usado no iOS via MoltenVK. A criação da superfície registra quantas
amostras do guest correspondem a cada texel, sem duplicar a expansão que já
ocorre no início da cena. Leituras e offsets de cópia usam essa mesma grade,
inclusive quando a cena seguinte muda o modo de downscale. O lookup reconhece
o padding de alocações tiled; cópias limitam a região à imagem e inicializam
a borda restante com profundidade 1/stencil 0. Leituras que começam apenas no
padding são recusadas. Não foi necessário importar o cache inteiro do Plus,
o resampling de depth entre passes ou seu heurístico de blit por aspect ratio.

Teste opcional com GPU real, sem jogos/firmware, no host:

```sh
cmake -S . -B build/macos-ninja -DVITA3K_BUILD_GPU_TESTS=ON
cmake --build build/macos-ninja --config Release --target renderer-depth-cache-tests
VULKAN_LOADER="$(brew --prefix molten-vk)/lib/libMoltenVK.dylib" \
  ctest --test-dir build/macos-ninja -C Release -R '^renderer-depth-cache$' --output-on-failure
```

Requer `glslc` e um driver Vulkan; em outros hosts, `VULKAN_LOADER` pode apontar
ao loader instalado ou ser omitido para usar o padrão. O teste usa o cache de
produção e confere na GPU as dimensões e cada texel de um padrão de depth e
stencil: 180 combinações de MSAA desligado/2x/4x, downscale, resolução
1x/1,5x/2x, leitura direta, feedback do attachment, sub-regiões e tiles parciais.
Também verifica rejeição de leituras fora da alocação e apenas no padding.
**A confirmação visual do outline no jogo e no iPhone continua pendente.**

### Performance Overlay

Ative em **Opções → Performance Overlay** ou na seção global da configuração
de um jogo. O painel aparece no canto superior esquerdo durante a sessão e
atualiza a cada segundo, mesmo com logs e diagnósticos desativados.

- **FPS**: delta do contador atômico de chamadas válidas a
  `sceDisplaySetFrameBuf` dividido pelo tempo monotônico decorrido. Conta
  quadros enviados pelo jogo, não VBlanks nem reapresentações do host.
- **Quadro**: intervalo médio por quadro nessa janela (`1000 / FPS`). Não é
  tempo de GPU nem latência do toque até a imagem; esses dados não são medidos.
  Sem quadros, mostra 0 FPS e tempo indisponível. Pausa/reinício descartam a
  amostra anterior, evitando valores antigos ou médias com tempo em pausa.
- **RAM**: footprint do processo (`TASK_VM_INFO.phys_footprint`), em MiB.
  Inclui memória de CPU e páginas gráficas contabilizadas pelo iOS.
- **GPU aloc.**: bytes alocados pelo dispositivo Metal da superfície
  (`MTLDevice.currentAllocatedSize`), em MiB. É uma métrica de alocação, não
  VRAM física dedicada. Não é somada à RAM, pois há memória compartilhada.
  Dados indisponíveis aparecem como `—`; o simulador não fornece a medição
  de alocações Metal, que fica disponível apenas no aparelho.

Referências: [memória de jogos no Apple silicon](https://developer.apple.com/videos/play/wwdc2022/10106/)
e [alocações Metal](https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize).

Para depurar o código nativo, configure explicitamente com
`-DCMAKE_BUILD_TYPE=Debug`, recompile/stage e escolha Debug também no Xcode.
Para voltar à build de uso normal, reexecute o preset sem esse override.

Se o checkout não tiver os metadados Git do submódulo FFmpeg, informe a revisão
fixada ao configurar o simulador: `cmake --preset ios-simulator
-DVITA3K_FFMPEG_SHA=e744193`. Essa revisão corresponde aos prebuilts documentados
em `ios-plan.md`; em um checkout com submódulos completos, a detecção é automática.

## O que o app faz

- Ao abrir/voltar ao primeiro plano, verifica e prepara a arena JIT em
  background. No aparelho, abra pelo StikDebug com **Universal**. Sem JIT,
  mostra um aviso e permite organizar/importar a biblioteca, mas impede o
  lançamento de jogos. `CS_DEBUGGED` sozinho não é tratado como prova de JIT.
- Biblioteca e opções usam layouts adaptativos; a superfície UIKit respeita
  safe areas e teclado. Controles ficam abaixo da imagem em retrato e nas
  laterais em paisagem. Preferências de controles/opacidade, painel de desempenho
  e apresentação da biblioteca são persistidas localmente.
- Em **Opções → Controles e tela**, **Forçar rotacionamento na horizontal**
  mantém a interface e os jogos em paisagem mesmo com o iPhone em pé. A opção
  tem efeito imediato e fica salva entre sessões; desativá-la restaura a rotação
  automática conforme o aparelho.
- Mostra a versão do core (`vita3k_ios_version`).
- "Self-test" executa `vita3k_ios_self_test` (bridge C em
  `vita3k/ios/include/ios/bridge.h`): inicializa o `Root` no sandbox
  (`Documents/`), liga o logging do core (`Documents/logs/vita3k.log`),
  verifica primitives (fmt, boost::filesystem, page size) e reporta o estado
  da arena JIT (`prepared`/`not prepared`).
- "Memória", em Opções → Diagnóstico avançado, executa
  `vita3k_ios_memory_test` em background. É opcional e não roda no launch.
- "JIT report" mostra o relatório da arena (`vita3k_ios_jit_report`).
- Grava `Documents/app-probe.txt` (rc + relatório do self-test),
  `Documents/memory-probe-report.txt` (rc + relatório do memory test) e
  `Documents/memory-probe.txt` (marcas de fase — se o processo morrer no
  meio do teste, a última linha mostra em que fase morreu) para inspeção via
  `xcrun simctl get_app_container` / `devicectl`.

## Ícone do app

O ícone é gerado diretamente do [`logo.png`](../../logo.png) na raiz do
repositório. A imagem deve ser quadrada; o script preserva a arte, a borda e o
enquadramento fornecidos, apenas redimensionando e codificando o PNG em
1024×1024 RGB opaco. O iOS aplica sua própria máscara de cantos.

Ambas as flavors selecionam `AppIcon` em
`App/Assets.xcassets/AppIcon.appiconset`; o Xcode gera os tamanhos usados pelo
iPhone e iPad. Após atualizar `logo.png`, regenere o ícone usando ImageMagick:

```sh
python3 ios/Vita3K/scripts/render-app-icon.py
```

O `logo.png` original é preservado; não há uma cópia intermediária da arte.

## Cache JIT por jogo

Segure o ícone → **Editar Config → CPU e GPU (este jogo) → Cache JIT por thread**.
O padrão é **Auto**: usa o perfil do jogo no core, ou o tamanho global quando
não existe um perfil (atualmente 16 MiB). No iOS, Atelier Sophie (`PCSE00892`)
e Senran Kagura Shinovi Versus (`PCSE00398`) usam 8 MiB em Auto; os perfis foram
validados com as versões 1.00. A tela mostra o tamanho usado por Auto.

Também é possível escolher **8, 12, 16, 20, 24, 28 ou 32 MiB**. A escolha é
salva no XML do título e aplicada quando o jogo for reiniciado. Valores
numéricos existentes permanecem como escolhas manuais. Selecionar Auto
restaura a regra do core sem apagar outras opções; remover a configuração
própria também retorna a Auto. No XML, `cpu-jit-cache-mib="0"` representa Auto,
resolvido para um tamanho real antes da criação das threads.

O tamanho é por thread, dentro da reserva JIT compartilhada. Valores menores
permitem mais threads simultâneas e podem ajudar jogos presos no loading por
falta de espaço JIT, mas podem aumentar a recompilação de código. Alterar essa
opção não aumenta a reserva total nem muda os outros jogos.

`JITCacheConfigTests` verifica Auto/perfis, persistência dos sete tamanhos,
isolamento entre jogos, preservação de outras opções, reset e valores inválidos.
`InterfaceTests.testJITCachePickerPersistsPerGame` cobre o menu e a persistência
após reabrir o app, com um título descartável `JITCACHE1` configurado em 8 MiB.

## Precisão de Renderização por jogo

Segure o ícone → **Editar Config → CPU e GPU (este jogo) → Precisão de Renderização**
(Rendering Accuracy). Escolha **Padrão (Standard)** ou **Alta (High)**; a opção
é salva por jogo e aplicada ao reiniciá-lo. Alta pode melhorar a precisão dos
gráficos, com possível redução de desempenho.

No iOS, Killzone Mercenary (`PCSA00107` e `PCSF00403`) usa **Alta** por padrão.
Outros títulos seguem a configuração global. Um valor `high-accuracy` já salvo
no XML tem prioridade, inclusive `false` (Padrão); arquivos sem esse atributo
herdam o padrão do título. Remover a configuração própria restaura o padrão.

## Apagar jogos

Segure o ícone de um jogo na biblioteca e escolha **Apagar jogo**. A opção
funciona na grade, na lista e no cartão do último jogo, mesmo sem JIT.
A confirmação informa qual título será apagado; **Cancelar** mantém tudo.

A exclusão remove a instalação, atualizações, DLCs exclusivos do título,
licenças, configuração própria e caches de shaders do armazenamento. Também
limpa favoritos e último jogo e atualiza a biblioteca. Saves, troféus e os
arquivos originais em `imports/` são preservados. Para jogar novamente,
importe o jogo. A operação roda em background, impede lançamento/importação
simultâneos e informa falhas de remoção.

`GameDeletionTests` verifica arquivos removidos, dados preservados, favoritos,
identificadores inválidos, links simbólicos e falha de I/O com nova tentativa.
`InterfaceTests.testDeleteGameFromGridAndListWithoutJIT` usa uma pasta
descartável `Documents/vita/ux0/app/DELETEUI1` criada antes do teste; cobre
cancelamento na grade, exclusão na lista e persistência após reabrir o app.

## Saves no iCloud

Em **Opções → Saves no iCloud**, ative **Sincronizar todos os saves** (desligado
por padrão). O app sincroniza `vita/ux0/user/*/savedata/*`, incluindo outros
usuários e saves de jogos desinstalados. Jogos, firmware, troféus, configurações
e save states não fazem parte dessa sincronização.

A sincronização ocorre na biblioteca, ao abrir/retomar o app, depois de encerrar
um jogo e antes de iniciar outro. **Sincronizar agora** permite tentar novamente.
O app aguarda o encerramento real da sessão; pausar ou colocar um jogo em
background não libera seus arquivos para sincronização. Sem acesso ao iCloud,
os saves locais continuam disponíveis para jogar. Antes de trocar de aparelho,
encerre o jogo e aguarde **Todos os saves estão sincronizados**. A indicação
**Aguardando envio** significa que o iCloud ainda não confirmou o upload.

Cada versão de um save é um documento binário `.vitasave` completo e imutável,
com hash de conteúdo e identificação dos seus ancestrais. Isso evita misturar
arquivos de sessões diferentes e preserva alterações concorrentes/offline sem
escolher um vencedor pelo relógio do aparelho. Se houver conflito, escolha a
versão local ou uma das versões do iCloud nas opções antes de abrir um jogo.
A escolha é revalidada antes de aplicar; uma versão que mudou exige nova escolha.

As versões anteriores permanecem em **iCloud Drive → Flowyr → Saves** e ocupam
espaço na conta. Cópias locais anteriores a uma substituição ficam em
`Documents/Save Backups/<usuário>/<jogo>/`. Ambas usam o formato `.vitasave`
(property list binária; `entries` contém caminhos relativos e os dados de cada
arquivo, com diretórios representados por ausência de `data`). Esses documentos
não devem ser copiados diretamente para a pasta `savedata`: é necessário
extrair suas entradas para recuperar os arquivos originais. Desativar a opção
preserva todas as cópias. Apagar uma pasta local de save não apaga o iCloud; ela
será restaurada na próxima sincronização.

### Configuração da assinatura

Os dois projetos XcodeGen declaram iCloud Documents (`CloudDocuments`) e usam
`ICLOUD_CONTAINER_IDENTIFIER = iCloud.dev.vita3k.Flowyr`. No Apple Developer,
o App ID e o provisioning profile precisam autorizar esse container. Para outra
equipe/App ID, configure um container próprio nessa variável nos dois YAMLs e
na chave de `NSUbiquitousContainers` do `App/Info.plist` (o Xcode só expande
variáveis em valores, não em chaves). Gere o projeto novamente.
Todos os aparelhos devem usar o mesmo container e
a mesma conta do iCloud, com iCloud Drive habilitado. Assinaturas/sideload que
removem os entitlements do iCloud continuam rodando o app, mas a opção informa
que o serviço está indisponível. Referência: [configuração de iCloud no Xcode](https://developer.apple.com/documentation/xcode/configuring-icloud-services).

`SaveSyncTests` exercita cópia entre aparelhos simulados por diretórios isolados,
todos os usuários, restauração integral, conflitos offline, escolhas obsoletas,
troca de conta, backups, erros de I/O e rejeição de caminhos/links inseguros.
Uma validação real do transporte iCloud exige dois aparelhos assinados com o
container autorizado e a mesma conta; os testes locais não validam a rede Apple.

## Acesso pelo app Arquivos

No iPhone, abra **Arquivos → Explorar → No Meu iPhone → Flowyr**.
No iPad, use **No Meu iPad → Flowyr**.
A pasta expõe os documentos do emulador para copiar, mover, renomear e
apagar arquivos. `UIFileSharingEnabled` e `LSSupportsOpeningDocumentsInPlace`
estão habilitados no `Info.plist` compartilhado pelas builds de device e
simulador; os mesmos documentos também ficam acessíveis pelo Finder no Mac.

- `vita/ux0/app/`: jogos instalados, separados por title ID.
- `vita/ux0/user/<usuário>/savedata/`: saves (normalmente o usuário é `00`).
- `config/`: configurações globais e por jogo.
- `imports/`: arquivos `.zip`, `.vpk`, `.pkg` e `.pup` para importação pelo app.
- `cache/`, `patch/`, `shared/`, `logs/` e `diagnostics/`: caches, patches,
  recursos compartilhados e registros de diagnóstico, quando presentes.

Encerre o jogo antes de substituir seus saves ou editar sua configuração.
Os arquivos existentes já estão nesses diretórios; não é necessária migração.

## Testes da interface

Depois de compilar o core de simulador:

```sh
ios/Vita3K/scripts/stage-core.sh simulator
xcodebuild test -project ios/Vita3K/Vita3K.xcodeproj -scheme Vita3K \
    -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -parallel-testing-enabled NO
```

A suite cobre aviso/bloqueio sem JIT e rotação de biblioteca, opções e
diagnóstico. O caso de jogo real requer `PCSE00890` já instalado no simulador;
se não existir, somente esse caso é marcado como skipped. A injeção de JIT
indisponível dos testes não é compilada para o aparelho.

O target de simulador `Vita3KInputTests` testa os controles UIKit com o bridge
e o `CtrlState` reais, sem precisar de jogo ou execução JIT. Cobre os botões
nos formatos normal e estendido, combinações, soltura/cancelamento, analógicos
e limpeza dos comandos na rotação sem desativar o controle visível. Para rodar
só esses testes, acrescente `-only-testing:Vita3KInputTests` ao `xcodebuild test`.
O relatório de sessão inclui `vpad`, `vpad_buttons`, `vpad_buttons_ext` e
`vpad_axes` para conferir o estado recebido pelo core.

## Upload de vértices e índices no Vulkan

No caminho sem mapeamento direto de memória (usado no iOS), os uploads usam
páginas próprias para cada um dos três quadros em voo. Uma página cheia abre
outra; sua memória só é reutilizada depois das fences do respectivo quadro.
Isso evita sobrescrever vértices que a GPU ainda precisa ler — causa dos
polígonos esticados na cena inicial de Atelier Sophie (`PCSE00892` 1.00).

As páginas de vértices têm 16 MiB e as de índices 4 MiB, crescendo para uploads
individuais maiores. A capacidade máxima usada permanece alocada e é
reaproveitada até destruir o contexto; portanto, cenas pesadas podem consumir
mais memória que os antigos buffers circulares fixos de 64 MiB.

Regressão com leitura real pela GPU, ASan e UBSan, no Mac:

```sh
ios/Vita3K/scripts/test-frame-upload.sh
```

Requer o preset `ios-device` configurado e MoltenVK instalado pelo Homebrew
(ou `VULKAN_LOADER` apontando para a biblioteca). O teste cobre esgotamento de
páginas, upload maior que uma página, três quadros pendentes e reutilização
após conclusão. A comparação visual do jogo continua exigindo o iPhone.

## Modelo de memória (etapa 5)

Política do core no iOS (implementada/validada em
`vita3k/ios/src/memory_test.cpp`, chamada de `vita3k_ios_memory_test`):

- **Reserva do guest:** `mem::init` reserva **4 GiB contíguos** com
  `mmap(PROT_NONE, MAP_ANONYMOUS|MAP_PRIVATE)` (hint `1<<34`; o kernel pode
  realocar — o core sempre usa a base real). Reserva virtual: não consome RAM
  até as páginas guest serem commitadas.
- **Páginas:** guest tem páginas de **4 KiB**; o host (iOS 26 / Apple
  Silicon) tem páginas de **16 KiB**. Todo commit/protect/unprotect no
  `mem.cpp` já alinha à página do host; um host page só é decommit
  (`mprotect(PROT_NONE)` + `madvise(MADV_DONTNEED)`) quando **todas** as 4
  páginas guest que o compõem estão livres. Consequência documentada e
  testada: proteger uma página guest de 4 KiB cobre o host page de 16 KiB
  inteiro até a primeira fault; a fault (handler `SIGBUS`/`SIGSEGV` →
  `ProtectCallback` → unprotect) devolve o host page inteiro ao acesso.
- **Falhas de memória:** `PROT_NONE` gera `SIGBUS` no Apple; o handler
  registrado em `mem::init` (`mem.cpp`) converte para `handle_access_violation`
  (callback de write-protect do kernel HLE). Acesso a região inválida (ex.:
  nulo do guest) é falha controlada: `LOG_CRITICAL` + `SIGTRAP`.
- **JIT:** todo código executável vive na **arena dual-map RX/RW**
  (`vita::ios::JitMemory`) — reserva `mmap(PROT_READ|PROT_EXEC)` + alias RW
  via `vm_remap`, preparada no device pela sessão StikDebug (`brk #0xf00d`),
  validada em `ios/JitDynTest`. **Nunca** `MAP_JIT` (negado sob TXM) nem
  `mprotect` para RX em mapp comum. Emissão pelo alias RW → flush
  (`dc civac` RW + `ic ivau` RX + `dsb ish` + `isb`) → execução pela vista RX.
  O preflight reserva **512 MiB por processo**, com o mesmo padrão compartilhado
  pela configuração e pelo teste de memória (`util/jit_config.h`). O cache
  padrão de 16 MiB por thread comporta até 32 alocações simultâneas; títulos
  configurados com 8 MiB comportam até 64, sem outras fatias ocupadas. Esse
  orçamento guarda código traduzido e é separado da RAM/VRAM do Vita. O
  aumento exige reiniciar e preparar o JIT novamente pelo StikDebug. Uma
  configuração por jogo não redimensiona uma arena já preparada. Conferir
  `reserved`/`free` nos logs para verificar a capacidade efetiva, especialmente
  com configs antigas; acompanhar a memória física durante o reteste.
- **Orçamento de RAM (jetsam):** `os_proc_available_memory()` reporta o
  orçamento default por app — medido **3 GiB** no iPhone 17 Pro (12 GB,
  iOS 26.7); Apple documenta o "default app memory limit" e o entitlement
  `com.apple.developer.kernel.increased-memory-limit` para modelos
  suportados (candidato a etapa 11, se títulos pesados apertarem). A reserva
  de 4 GiB **não** consome esse orçamento (é virtual, `PROT_NONE`); apenas
  as páginas guest commited (RW) contam. Reportes de ~6 GiB por app
  aparecem no iOS 27 — re-medir após o update (o próprio teste mostra o
  número na linha `app_memory_budget`).
- **VA:** o app pede o entitlement
  `com.apple.developer.kernel.extended-virtual-addressing`
  (`App/Vita3K.entitlements`) para ampliar o teto de VA do processo; o
  memory test mede o teto efetivo (probes de `PROT_NONE` de 1 GiB a 1 TiB,
  com e sem o hint de produção `1<<34`) e reporta se o EAV está ativo.
  No iOS 26.7 / perfil atual ele não teve efeito observável (teto inalterado);
  o bloco de 4 GiB ainda assim reserva com sucesso, pois o kernel pode
  realocar a hint. **Nota:** um segundo reserva de 4 GiB simultâneo é
  recusado no device (VA budget) — o produto usa um `MemState` por processo.

Validação em device: o memory test roda em background; **sem** StikDebug a
arena fica `not prepared` e a seção E é reportada como *skipped* (não como
falha) — o restante do modelo de memória é validado. **Com** o app lançado
pelo StikDebug, a seção E prepara a arena (protocolo `brk #0xf00d`, ~10
tentativas em ~15 s para cobrir o armamento do script) e executa o
bootstrap JIT (código emitido em RW, executado em RX, lendo/escrevendo
páginas guest da reserva de 4 GiB). O relatório fica em
`Documents/memory-probe-report.txt` (copiar com `devicectl device copy from`,
ver seção de debug abaixo).
**Cuidados:** o pareamento do StikDebug é invalidado ao reinstalar o app
(cdhash novo) — re-pareie o build atual antes de testar; e um re-launch
normal (sem StikDebug) sobrescreve o relatório com um run *skipped*.

## Notas

- O dylib é copiado e **assinado** pelo script `Stage Vita3KCore` (fase
  pre-build, antes do Code Sign do app) para a raiz do bundle; o install name
  `@rpath/libVita3KCore.dylib` resolve via `@executable_path`. No device, um
  Mach-O aninhado sem assinatura impede o dyld de carregar o dylib e o app
  morre antes de `main()` (tela branca, exit 0, sem crash report) — por isso
  a assinatura precisa acontecer antes da fase Code Sign do bundle.
- Símbolos Vulkan do dylib ficam undefined (`-undefined dynamic_lookup`): no
  device o XCFramework estático do MoltenVK é linkado no app; no simulador o
  core só inicializa (sem Vulkan) até existir um MoltenVK com slice sim.
- Assinatura: device usa a identidade de desenvolvedor do Xcode
  (resolvida via `security find-identity`); simulador
  assina ad-hoc.

## Debug em device real (sem Xcode)

Com o iPhone conectado e pareado (`xcrun devicectl list devices`):

```sh
DEV=<identifier do devicectl>   # UUID do CoreDevice, não o UDID físico
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Vita3K-*/Build/Products/Debug-iphoneos/Vita3K.app | head -1)

xcrun devicectl device install app --device $DEV "$APP"
xcrun devicectl device process launch --device $DEV --activate dev.vita3k.Flowyr
# console ao vivo (dyld errors, stdout do app):
xcrun devicectl device process launch --console --device $DEV dev.vita3k.Flowyr

# arquivos do sandbox (listar / baixar):
xcrun devicectl device info files --device $DEV --domain-type appDataContainer --domain-identifier dev.vita3k.Flowyr
xcrun devicectl device copy from --device $DEV --domain-type appDataContainer \
    --domain-identifier dev.vita3k.Flowyr --source Documents/app-probe.txt --destination /tmp/app-probe.txt

xcrun devicectl device capture screenshot --device $DEV --destination /tmp/screen.png
```

O app grava em `Documents/`: `app-probe.txt` (rc + relatório do self-test),
`memory-probe-report.txt` (rc + relatório do memory test, etapa 5),
`memory-probe.txt` (marcas de fase do memory test) e
`startup-probe.txt` (trilha de inicialização: app init → onAppear → chamadas
C) e `logs/vita3k.log` (logging do core). São a principal janela de
diagnóstico, pois device não tem console.
