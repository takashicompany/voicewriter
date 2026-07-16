import AppKit
import Carbon.HIToolbox
import os.log

enum TextInsertionError: Error, CustomStringConvertible {
    case accessibilityNotTrusted
    case eventCreationFailed
    /// `sendCommandV()`送出直前の最終確認で、期待していたフロントモストアプリ(録音開始時点の
    /// もの)と実際のフロントモストアプリが一致しなかった(Codexレビュー指摘#4)。
    case focusChanged

    var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "accessibility permission not granted"
        case .eventCreationFailed:
            return "failed to create CGEvent for Cmd+V"
        case .focusChanged:
            return "frontmost app changed just before paste"
        }
    }
}

/// `DeliveryCoordinator`が挿入を行うために必要な最小限のインターフェース。
/// 実装は`TextInserter`(実際にCGEventでCmd+Vを合成する)だが、単体テストでは
/// 実際のアクセシビリティ権限・キーイベント送出に依存しないフェイクに差し替えられるようにしている。
protocol TextInserting: AnyObject {
    /// - Parameters:
    ///   - text: 挿入するテキスト。
    ///   - expectedFrontmostProcessIdentifier: 録音開始時点のフロントモストアプリのPID。
    ///     `DeliveryCoordinator`は挿入直前に一度フォーカスを比較しているが、そこから実際に
    ///     `sendCommandV()`を送出するまでの間(このメソッド内で`await`を挟む)にユーザーが
    ///     アプリを切り替えるTOCTOUが起こりうるため、送出直前にもう一度最終確認する
    ///     (Codexレビュー指摘#4)。`nil`の場合は確認をスキップする。不一致の場合は
    ///     `TextInsertionError.focusChanged`をthrowし、Cmd+V自体は送出しない。
    ///   - onPasted: 実際にCmd+Vを送出した直後(ペーストボード復元待ちより前)に呼ばれる。
    ///     呼び出しごとの引数として渡すこと(共有プロパティにすると、複数ジョブの挿入が
    ///     重なった際にどのジョブの完了通知か混同しうるため。過去に共有プロパティ方式で
    ///     この競合が実際に指摘されたことがある)。
    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws
}

extension TextInserting {
    /// `expectedFrontmostProcessIdentifier`を省略した呼び出し用の便宜的なオーバーロード
    /// (フォーカス確認が不要な呼び出し元向け。テストでの記述量削減にも使う)。
    func insert(text: String, onPasted: @escaping () -> Void = {}) async throws {
        try await insert(text: text, expectedFrontmostProcessIdentifier: nil, onPasted: onPasted)
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
final class TextInserter: TextInserting {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "TextInserter")

    /// Cmd+V送出後、ペーストボードを復元するまでの待ち時間(秒)。
    /// ペースト先アプリがペーストボードを読み終えるのを待つための猶予。
    var restoreDelaySeconds: Double = 0.4

    private let isAccessibilityTrusted: () -> Bool
    private let sendCommandV: () throws -> Void
    /// 現在のフロントモストアプリのPIDを取得する。`sendCommandV()`送出直前の最終フォーカス確認
    /// (Codexレビュー指摘#4)用に差し替え可能にしている(テスト用、既定は実際のAPI)。
    private let currentFrontmostProcessIdentifier: () -> pid_t?

    /// `insert(text:expectedFrontmostProcessIdentifier:onPasted:)`は内部で`Task.sleep`を挟むため、
    /// 呼び出しが重なるとスナップショットの保存・復元が競合しうる。直列化するため、前回呼び出しの
    /// 完了を待ってから実行する。
    private var pendingTask: Task<Void, Error>?

    /// - Parameters:
    ///   - isAccessibilityTrusted: アクセシビリティ権限確認の差し替え用(テスト用、既定は実際のAPI)。
    ///   - sendCommandV: 実際のCmd+V送出処理の差し替え用(テスト用、既定は実際にCGEventを送出する)。
    ///   - currentFrontmostProcessIdentifier: フォーカス最終確認用のフロントモストアプリPID取得の
    ///     差し替え用(テスト用、既定は実際のAPI)。
    init(
        isAccessibilityTrusted: @escaping () -> Bool = { AccessibilityPermission.isTrusted },
        sendCommandV: (() throws -> Void)? = nil,
        currentFrontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.sendCommandV = sendCommandV ?? Self.postCommandV
        self.currentFrontmostProcessIdentifier = currentFrontmostProcessIdentifier
    }

    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        let previous = pendingTask
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            try await self?.performInsert(text: text, expectedFrontmostProcessIdentifier: expectedFrontmostProcessIdentifier, onPasted: onPasted)
        }
        pendingTask = task
        try await task.value
    }

    private func performInsert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        guard isAccessibilityTrusted() else {
            log.warning("Cannot insert text: accessibility permission not trusted")
            throw TextInsertionError.accessibilityNotTrusted
        }
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // sendCommandV()送出直前の最終フォーカス確認(Codexレビュー指摘#4)。`DeliveryCoordinator`側の
        // 確認からここまでの間(pendingTaskの直列化待ちを含む)にユーザーがアプリを切り替える
        // TOCTOUが起こりうるため、実際にCmd+Vを送出する直前にもう一度確認する。
        if let expectedFrontmostProcessIdentifier, currentFrontmostProcessIdentifier() != expectedFrontmostProcessIdentifier {
            // ペーストボードは書き換え済みのため、送出せずに元へ戻す。
            snapshot.restore(to: pasteboard)
            throw TextInsertionError.focusChanged
        }

        do {
            try sendCommandV()
        } catch {
            // ペースト送出に失敗した場合は復元まで待たず即座に元へ戻す
            snapshot.restore(to: pasteboard)
            throw error
        }
        onPasted()

        try? await Task.sleep(nanoseconds: UInt64(max(0, restoreDelaySeconds) * 1_000_000_000))

        if pasteboard.changeCount == ourChangeCount {
            snapshot.restore(to: pasteboard)
            log.debug("Pasteboard restored to previous contents")
        } else {
            log.debug("Pasteboard changed by another process during paste; leaving as-is")
        }
    }

    private static func postCommandV() throws {
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
