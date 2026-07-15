import XCTest
@testable import Voicewriter

/// 状態表示HUD・効果音のON/OFF設定(`Settings.hudEnabled`/`Settings.soundEffectsEnabled`)の
/// デフォルト値・永続化の回帰テスト。両方とも既定ON。
final class HUDSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.hudEnabled)
        UserDefaults.standard.removeObject(forKey: SettingsKey.soundEffectsEnabled)
        super.tearDown()
    }

    func testHudEnabledDefaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.hudEnabled)
        XCTAssertTrue(Settings.hudEnabled)
    }

    func testHudEnabledPersistsExplicitFalse() {
        Settings.hudEnabled = false
        XCTAssertFalse(Settings.hudEnabled)
    }

    func testSoundEffectsEnabledDefaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.soundEffectsEnabled)
        XCTAssertTrue(Settings.soundEffectsEnabled)
    }

    func testSoundEffectsEnabledPersistsExplicitFalse() {
        Settings.soundEffectsEnabled = false
        XCTAssertFalse(Settings.soundEffectsEnabled)
    }
}
