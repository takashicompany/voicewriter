import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-Talk: 押している間だけ録音 (デフォルト: F13, 修飾キーなし)
    static let pushToTalk = Self("pushToTalk", default: .init(.f13))

    /// トグル: キーを離した瞬間にON/OFF切替 (デフォルト: ⌥⇧Space)
    static let toggleRecording = Self("toggleRecording", default: .init(.space, modifiers: [.option, .shift]))

    /// 録音中のキャンセル (デフォルト: Esc)
    static let cancelRecording = Self("cancelRecording", default: .init(.escape))
}
