#include <gui-qt/cloud_saves.h>
#include <gui-qt/branding.h>

#include <QApplication>
#include <QCheckBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QIcon>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QPushButton>
#include <QScrollArea>
#include <QSignalBlocker>
#include <QTimer>
#include <QVBoxLayout>

extern "C" {
void flowyr_cloud_tick(const char *root, bool safe);
bool flowyr_cloud_busy();
void flowyr_cloud_enable(bool enabled);
void flowyr_cloud_request();
void flowyr_cloud_resolve(const char *key, const char *revision);
char *flowyr_cloud_state();
void flowyr_cloud_free(char *state);
}

CloudSaves::CloudSaves(QWidget *parent, std::function<QString()> root, std::function<bool()> idle)
    : QObject(parent), m_root(std::move(root)), m_idle(std::move(idle)) {
    auto *timer = new QTimer(this);
    connect(timer, &QTimer::timeout, this, &CloudSaves::tick);
    timer->start(500);
    connect(qApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
        if (state == Qt::ApplicationActive)
            request();
    });
}

bool CloudSaves::busy() const { return flowyr_cloud_busy(); }

bool CloudSaves::safe() const {
    return m_idle() && !QApplication::activePopupWidget()
        && (!QApplication::activeModalWidget() || QApplication::activeModalWidget() == m_dialog);
}

void CloudSaves::request() { flowyr_cloud_request(); }

void CloudSaves::tick() {
    const auto path = m_root().toUtf8();
    flowyr_cloud_tick(path.constData(), safe());
    refresh();
}

void CloudSaves::resolve(const QString &key, const QString &revision) {
    if (!safe() || busy())
        return;
    flowyr_cloud_resolve(key.toUtf8().constData(), revision.toUtf8().constData());
    refresh();
}

void CloudSaves::refresh() {
    const bool now_busy = busy();
    if (m_busy != now_busy) {
        m_busy = now_busy;
        emit busy_changed(m_busy);
    }
    if (!m_dialog)
        return;
    char *json = flowyr_cloud_state();
    const auto state = QJsonDocument::fromJson(json ? QByteArray(json) : QByteArray()).object();
    flowyr_cloud_free(json);
    const QSignalBlocker block(m_enabled);
    m_enabled->setChecked(state["enabled"].toBool());
    m_enabled->setEnabled(!now_busy);
    m_status->setText(state["status"].toString());
    const QString date = state["lastCheck"].toString();
    m_last_check->setText(date.isEmpty() ? QString() : QStringLiteral("Última verificação: ") + date);
    m_sync->setEnabled(state["enabled"].toBool() && !now_busy && safe());
    m_conflicts->setEnabled(!now_busy && safe());
    const auto versions = state["conflicts"].toArray();
    if (versions == m_versions)
        return;
    m_versions = versions;
    while (auto *item = m_conflict_layout->takeAt(0)) {
        delete item->widget();
        delete item;
    }
    for (const auto &value : versions) {
        const auto conflict = value.toObject();
        const QString key = conflict["id"].toString();
        auto *label = new QLabel(QStringLiteral("%1 · Usuário %2\nEscolha o progresso que deseja continuar. A versão substituída será preservada.")
                                    .arg(conflict["game"].toString(), conflict["user"].toString()), m_conflicts);
        label->setWordWrap(true);
        m_conflict_layout->addWidget(label);
        if (conflict["local"].toBool()) {
            auto *button = new QPushButton(QStringLiteral("Usar save deste Mac"), m_conflicts);
            connect(button, &QPushButton::clicked, this, [this, key] { resolve(key, {}); });
            m_conflict_layout->addWidget(button);
        }
        for (const auto &entry : conflict["versions"].toArray()) {
            const auto version = entry.toObject();
            auto *button = new QPushButton(QStringLiteral("Usar iCloud · %1 · %2")
                                              .arg(version["device"].toString(), version["date"].toString()), m_conflicts);
            connect(button, &QPushButton::clicked, this, [this, key, version] { resolve(key, version["id"].toString()); });
            m_conflict_layout->addWidget(button);
        }
    }
}

void CloudSaves::show_settings() {
    if (!m_dialog) {
        m_dialog = new QDialog(qobject_cast<QWidget *>(parent()));
        m_dialog->setWindowTitle(QStringLiteral("Flowyr — Saves no iCloud"));
        m_dialog->setWindowIcon(QIcon(gui::app_icon_resource));
        m_dialog->setObjectName(QStringLiteral("icloud-saves-settings"));
        m_dialog->resize(570, 480);
        auto *layout = new QVBoxLayout(m_dialog);
        m_enabled = new QCheckBox(QStringLiteral("Sincronizar todos os saves"), m_dialog);
        m_enabled->setObjectName(QStringLiteral("icloud-saves-toggle"));
        layout->addWidget(m_enabled);
        auto *description = new QLabel(QStringLiteral(
            "Compartilha os saves com o iPhone, iPad e outros Macs usando a mesma conta do iCloud. "
            "Encerre o jogo e aguarde o envio antes de trocar de aparelho. "
            "A sincronização aguarda o fechamento de jogos e de outras janelas de configuração."), m_dialog);
        description->setWordWrap(true);
        layout->addWidget(description);
        m_status = new QLabel(m_dialog);
        m_status->setObjectName(QStringLiteral("icloud-saves-status"));
        m_status->setWordWrap(true);
        layout->addWidget(m_status);
        m_last_check = new QLabel(m_dialog);
        layout->addWidget(m_last_check);
        m_sync = new QPushButton(QStringLiteral("Sincronizar agora"), m_dialog);
        m_sync->setObjectName(QStringLiteral("icloud-saves-sync"));
        layout->addWidget(m_sync);
        auto *note = new QLabel(QStringLiteral("Os saves locais continuam disponíveis para jogar offline. Versões anteriores e conflitos são preservados."), m_dialog);
        note->setWordWrap(true);
        layout->addWidget(note);
        auto *scroll = new QScrollArea(m_dialog);
        scroll->setWidgetResizable(true);
        m_conflicts = new QWidget(scroll);
        m_conflict_layout = new QVBoxLayout(m_conflicts);
        m_conflict_layout->setAlignment(Qt::AlignTop);
        scroll->setWidget(m_conflicts);
        layout->addWidget(scroll);
        auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, m_dialog);
        connect(buttons, &QDialogButtonBox::rejected, m_dialog, &QDialog::hide);
        layout->addWidget(buttons);
        connect(m_enabled, &QCheckBox::toggled, this, [this](bool enabled) { flowyr_cloud_enable(enabled); tick(); });
        connect(m_sync, &QPushButton::clicked, this, [this] { request(); tick(); });
    }
    tick();
    m_dialog->show();
    m_dialog->raise();
    m_dialog->activateWindow();
}
