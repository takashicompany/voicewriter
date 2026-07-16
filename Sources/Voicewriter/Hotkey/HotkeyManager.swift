import KeyboardShortcuts
import os.log

/// KeyboardShortcutsへの登録をまとめる。PTT(keyDown/keyUp)とトグル(keyUpのみ)を両立させる。
final class HotkeyManager {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "HotkeyManager")
    weak var coordinator: Coordinator?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        registerHandlers()
    }

    private func registerHandlers() {
        // PTT: keyDownで開始、keyUpで終了。
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            self?.log.debug("pushToTalk keyDown")
            Task { @MainActor in await self?.coordinator?.beginPushToTalk() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.log.debug("pushToTalk keyUp")
            Task { @MainActor in self?.coordinator?.endPushToTalk() }
        }

        // トグル: keyUp(離した瞬間)のみで判定するため、キーリピートによる暴発が起きない。
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.log.debug("toggleRecording keyUp")
            Task { @MainActor in await self?.coordinator?.toggleRecording() }
        }

        // 録音中のキャンセル
        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak self] in
            self?.log.debug("cancelRecording keyDown")
            Task { @MainActor in self?.coordinator?.cancelRecording() }
        }
    }
}
