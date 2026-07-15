import AppKit
import Carbon.HIToolbox
import os.log

enum TextInsertionError: Error, CustomStringConvertible {
    case accessibilityNotTrusted
    case eventCreationFailed

    var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "accessibility permission not granted"
        case .eventCreationFailed:
            return "failed to create CGEvent for Cmd+V"
        }
    }
}

/// Amical方式のカーソル位置へのテキスト挿入。
///
/// 1. `NSPasteboard.general` の現内容をスナップショット保存
/// 2. 認識テキストをペーストボードにセット
/// 3. CGEventでCmd+Vのkey down/upを合成してcgSessionEventTapへpost
/// 4. 少し待ってから、ペーストボードのchangeCountが自分の書き込み直後から
///    変わっていない場合のみ元の内容を復元する
///    (待機中に他プロセスがペーストボードを書き換えていたら、それを壊さないため復元しない)
@MainActor
final class TextInserter {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "TextInserter")

    /// Cmd+V送出後、ペーストボードを復元するまでの待ち時間(秒)。
    /// ペースト先アプリがペーストボードを読み終えるのを待つための猶予。
    var restoreDelaySeconds: Double = 0.4

    /// Cmd+Vを実際に送出した直後(ペーストボード復元待ちより前)に呼ばれる。
    /// HUD/効果音等、「挿入完了」を示すためのフック。挿入処理自体のタイミング・ロジックには影響しない。
    var onPasted: (() -> Void)?

    /// `insert(text:)`は内部で`Task.sleep`を挟むため、呼び出しが重なるとスナップショットの
    /// 保存・復元が競合しうる。直列化するため、前回呼び出しの完了を待ってから実行する。
    private var pendingTask: Task<Void, Error>?

    func insert(text: String) async throws {
        let previous = pendingTask
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            try await self?.performInsert(text: text)
        }
        pendingTask = task
        try await task.value
    }

    private func performInsert(text: String) async throws {
        guard AccessibilityPermission.isTrusted else {
            log.warning("Cannot insert text: accessibility permission not trusted")
            throw TextInsertionError.accessibilityNotTrusted
        }
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        do {
            try postCommandV()
        } catch {
            // ペースト送出に失敗した場合は復元まで待たず即座に元へ戻す
            snapshot.restore(to: pasteboard)
            throw error
        }
        onPasted?()

        try? await Task.sleep(nanoseconds: UInt64(max(0, restoreDelaySeconds) * 1_000_000_000))

        if pasteboard.changeCount == ourChangeCount {
            snapshot.restore(to: pasteboard)
            log.debug("Pasteboard restored to previous contents")
        } else {
            log.debug("Pasteboard changed by another process during paste; leaving as-is")
        }
    }

    private func postCommandV() throws {
        let vKeyCode = Self.resolveVKeyCode()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw TextInsertionError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    /// 現在のキーボードレイアウトで"V"を入力するための仮想キーコードを解決する。
    /// 解決できない場合はQWERTYのVK_ANSI_V(9)にフォールバックする。
    static func resolveVKeyCode() -> CGKeyCode {
        let fallback: CGKeyCode = 9 // kVK_ANSI_V

        guard let inputSourceUnmanaged = TISCopyCurrentKeyboardLayoutInputSource() else {
            return fallback
        }
        let inputSource = inputSourceUnmanaged.takeRetainedValue()

        guard let layoutDataRaw = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRaw).takeUnretainedValue() as Data

        // 実際に送出するイベントはCmd+Vのため、UCKeyTranslateの修飾キー状態もCmdを立てて解決する。
        // (Dvorak - QWERTY⌘のようにCmd押下時のみキー配列が変わるレイアウトに対応するため)
        // modifierKeyStateは古典的なEventRecord.modifiersを8bit右シフトしたエンコーディングを期待する。
        let cmdOnlyModifierKeyState = UInt32((cmdKey >> 8) & 0xFF)

        var chars: [UniChar] = [0, 0, 0, 0]

        for keyCode in UInt16(0)..<UInt16(128) {
            // dead-key状態は候補ごとにリセットする(前のキーの結果を引きずらないため)
            var keysDown: UInt32 = 0
            var actualLength = 0
            let status: OSStatus = layoutData.withUnsafeBytes { rawBuffer in
                guard let keyboardLayoutPtr = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                    return OSStatus(paramErr)
                }
                return UCKeyTranslate(
                    keyboardLayoutPtr,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    cmdOnlyModifierKeyState,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &keysDown,
                    chars.count,
                    &actualLength,
                    &chars
                )
            }

            guard status == noErr, actualLength > 0 else { continue }
            let text = String(utf16CodeUnits: chars, count: actualLength)
            if text.lowercased() == "v" {
                return CGKeyCode(keyCode)
            }
        }

        return fallback
    }
}

/// `NSPasteboard`の内容(全アイテム・全タイプ)を保存し、後で復元するためのスナップショット。
private struct PasteboardSnapshot {
    private struct ItemSnapshot {
        var dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private let items: [ItemSnapshot]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return ItemSnapshot(dataByType: dataByType)
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems: [NSPasteboardItem] = items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
