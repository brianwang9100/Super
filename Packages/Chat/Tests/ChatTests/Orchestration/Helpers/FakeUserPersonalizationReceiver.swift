import Foundation

@testable import Chat

actor FakeUserPersonalizationReceiver: UserPersonalizationReceiver {
    private var values: [String] = []

    func setUserPersonalization(_ value: String) async {
        values.append(value)
    }

    func received() -> [String] { values }
}
