import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: CoreController
    let importContent: () -> Void
    @AppStorage("library.listLayout") private var listLayout = false
    @AppStorage("library.sortByID") private var sortByID = false
    @AppStorage("emulation.showControls") private var showControls = true
    @AppStorage("emulation.controlOpacity") private var controlOpacity = 0.8
    @AppStorage("emulation.showStatus") private var showStatus = false
    @AppStorage(AppOrientation.preference) private var forceLandscape = false
    @AppStorage(EmulatorTheme.lightModePreference) private var lightMode = false
    @AppStorage(GameIconStyle.preference) private var classicIcons = false
    @AppStorage(AppLanguage.preference) private var language = AppLanguage.english.rawValue

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), alignment: .top)], alignment: .leading, spacing: 18) {
                EmulatorCard(title: "Idioma") {
                    Picker("Idioma da interface", selection: $language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.name).tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("interface-language")
                    Text("A alteração é aplicada imediatamente e fica salva para a próxima abertura. O idioma dos jogos não é alterado.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                EmulatorCard(title: "Aparência") {
                    Toggle("Tema claro", isOn: $lightMode)
                        .accessibilityIdentifier("light-mode-toggle")
                    Picker("Ícones dos jogos", selection: $classicIcons) {
                        Text("Arte larga").tag(false)
                        Text("Ícone clássico").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("game-icon-style")
                    Text("Arte larga usa a imagem de fundo do jogo. Ícone clássico usa o ícone quadrado do jogo.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Use fundos claros na biblioteca e nas opções. Desative para voltar ao tema escuro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                EmulatorCard(title: "Pronto para jogar") {
                    JITBadge(status: controller.jitStatus)
                    Text("No iPhone, abra o Veeb pelo StikDebug usando o script Universal. A disponibilidade do JIT é verificada ao abrir o app e antes de iniciar um jogo.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Verificar JIT agora") { Task { _ = await controller.checkJIT() } }
                        .disabled(controller.jitStatus == .checking)
                        .accessibilityIdentifier("check-jit")
                }
                EmulatorCard(title: "Controles e tela") {
                    Toggle("Forçar rotacionamento na horizontal", isOn: $forceLandscape)
                        .accessibilityIdentifier("force-landscape-toggle")
                    Text("Mantém a interface e os jogos na horizontal, mesmo com o aparelho em pé. Ao desativar, a rotação volta a acompanhar o aparelho.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Controles na tela", isOn: $showControls)
                        .accessibilityIdentifier("show-controls")
                    Text("Ocultados automaticamente ao conectar um controle físico.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Opacidade"); Spacer(); Text(controlOpacity, format: .percent.precision(.fractionLength(0))) }
                        .font(.subheadline)
                    Slider(value: $controlOpacity, in: 0.25...1, step: 0.05)
                        .accessibilityLabel("Opacidade dos controles").disabled(!showControls)
                    Toggle("Performance Overlay", isOn: $showStatus)
                        .accessibilityIdentifier("performance-overlay-toggle")
                    Text("FPS, tempo por quadro e memória. RAM inclui o uso contabilizado da GPU. “GPU aloc.” mostra as alocações gráficas na memória compartilhada; não é somado à RAM. Tempo por quadro não mede o atraso do toque até a tela.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Em retrato, a imagem fica acima dos controles; em paisagem, ocupa a área disponível sem distorcer a proporção.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                EmulatorCard(title: "Biblioteca") {
                    Toggle("Exibir como lista", isOn: $listLayout)
                    Toggle("Ordenar por título ID", isOn: $sortByID)
                    Text("Mantenha um jogo pressionado para adicioná-lo aos favoritos.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Atualizar jogos instalados") { controller.refreshApps() }
                }
                CloudSaveSettingsView(sync: controller.saveSync)
                EmulatorCard(title: "Sistema e conteúdo") {
                    LabeledContent("Áudio", value: "SDL · CoreAudio")
                    LabeledContent("Gráficos", value: "Vulkan · MoltenVK")
                    LabeledContent("Firmware") {
                        Text(controller.firmwareMask == 7 ? LocalizedStringKey("Instalado") : LocalizedStringKey("Incompleto"))
                    }
                    Text("Importe firmware PUP ou conteúdo de jogos VPK, ZIP, PKG e pastas. Ou use o app Arquivos: abra “No Meu iPhone” → “Veeb” — copie jogos para imports/ (instalados automaticamente) ou remova arquivos, ex. um jogo em vita/ux0/app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Importar conteúdo", systemImage: "square.and.arrow.down", action: importContent)
                        .disabled(controller.isImporting || !controller.sessionInitialized)
                }
                EmulatorCard(title: "Sobre o Veeb") {
                    Text("Vita is for Weebs").font(.headline)
                    LabeledContent("Núcleo") {
                        if controller.version.isEmpty { Text("Carregando…") }
                        else { Text(verbatim: controller.version) }
                    }
                    Text("Emulador experimental de PlayStation Vita para iOS. Compatibilidade e desempenho variam por jogo.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    NavigationLink { DiagnosticsView() } label: {
                        Label("Diagnóstico avançado", systemImage: "waveform.path.ecg")
                    }.accessibilityIdentifier("open-diagnostics")
                }
            }
            .padding(20).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .background(EmulatorTheme.background)
        .navigationTitle("Opções").navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var controller: CoreController
    @State private var jitDetails = ""
    private var busy: Bool { controller.jitStatus == .checking || controller.memRunning || controller.phase == .running || controller.isImporting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EmulatorCard(title: "Ferramentas de desenvolvimento") {
                    Text("Estes testes são opcionais. Não são necessários para abrir jogos e devem ser executados sem uma sessão ativa.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { testButtons }
                        VStack(alignment: .leading, spacing: 12) { testButtons }
                    }.buttonStyle(.bordered).disabled(busy)
                }
                reportCard("JIT", jitDetails)
                reportCard("Teste do núcleo", controller.report.isEmpty ? controller.failure : controller.report)
                reportCard("Memória", controller.memReport)
                reportCard("Log", controller.log)
            }.padding(20).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .background(EmulatorTheme.background)
        .navigationTitle("Diagnóstico").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var testButtons: some View {
        Button("Núcleo") { controller.runSelfTest() }
        Button("Estado do JIT") { jitDetails = controller.jitReport }
        Button("Memória") { controller.runMemoryTest() }.disabled(controller.jitStatus != .ready)
    }

    @ViewBuilder private func reportCard(_ title: LocalizedStringKey, _ report: String) -> some View {
        if !report.isEmpty {
            EmulatorCard(title: title) {
                Text(report).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
