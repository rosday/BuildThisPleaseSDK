import BuildThisPleaseCore
import BuildThisPleaseUI
import SwiftUI

/// WishKit-style convenience namespace for host-app integration.
public enum BuildThisPlease {
    /// Use as a destination inside the host app's existing navigation or menu.
    public struct FeedbackListView: View {
        private let client: any BuildThisPleaseClientProtocol

        public init(client: any BuildThisPleaseClientProtocol) {
            self.client = client
        }

        public var body: some View {
            BuildThisPleaseFeedbackView(client: client)
        }
    }

    /// Use when presenting feedback without an existing `NavigationStack`.
    public struct StandaloneFeedbackView: View {
        private let client: any BuildThisPleaseClientProtocol

        public init(client: any BuildThisPleaseClientProtocol) {
            self.client = client
        }

        public var body: some View {
            BuildThisPleaseBoard(client: client)
        }
    }
}
