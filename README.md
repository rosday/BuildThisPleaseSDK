# BuildThisPlease SDK

BuildThisPlease SDK is the private Swift package and SwiftUI interface used to add BuildThisPlease feedback boards to iOS apps.

This repository intentionally contains only client-side code, tests, localized resources, a privacy manifest, and a tiny example app. The BuildThisPlease Worker, administrator dashboard, database schema, production configuration, and deployment credentials remain in a separate private repository.

## Requirements

- Xcode 26 or newer
- Swift 6.2 or newer
- iOS 17 or newer

## Add the package

Add this private repository as a Swift Package dependency and select the `BuildThisPlease` product. Use a tagged release rather than a branch or commit whenever possible.

```swift
import BuildThisPlease
import SwiftUI

let configuration = try BuildThisPleaseConfiguration(
    projectKey: "btp_pk_your_publishable_project_key",
    environment: .production(
        baseURL: URL(string: "https://feedback.example.com")!
    ),
    subscriptionStatus: isTrial ? .trial : (isPro ? .pro : .free),
    revenueCatAppUserID: currentRevenueCatAppUserID,
    userEmail: signedInEmail
)

let feedbackClient = BuildThisPleaseClient(configuration: configuration)

struct SettingsMenu: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    BuildThisPlease.FeedbackListView(client: feedbackClient)
                } label: {
                    Label("Feature requests", systemImage: "lightbulb")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
```

`FeedbackListView` is designed to be pushed inside the host app's existing `NavigationStack`. Use `BuildThisPlease.StandaloneFeedbackView(client:)` when the feedback interface needs its own navigation container.

The project key and base URL identify the public mobile API and are not secrets. Never place Cloudflare credentials, administrator credentials, deployment tokens, or database credentials in an app or this package. Production mutations are protected by project scoping, App Attest, rate limits, and server-side authorization.

Each host app must have its Apple Team ID, bundle identifier, and App Attest environment registered in its corresponding BuildThisPlease project before production distribution.

## Verification

```bash
swift test
xcodebuild \
  -project Examples/BuildThisPleaseExample/BuildThisPleaseExample.xcodeproj \
  -scheme BuildThisPleaseExample \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/example-ci \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  build
```

## Access

The repository is private. Developers and CI systems need read access to resolve it. Do not redistribute its source or grant repository access beyond the people and systems that build an authorized host app.
