# BuildThisPlease SDK agent instructions

These instructions apply to coding agents integrating this package into a host Apple app.

## Scope and trust boundary

- This repository is the public client SDK. Do not assume access to the private Worker, dashboard, database, Cloudflare account, or customer data.
- The `btp_pk_…` project key is publishable identification, not authorization. Never invent a key, Team ID, bundle ID, or service URL.
- Never request or embed Cloudflare credentials, Access JWTs, dashboard cookies, database credentials, GitHub tokens, or Apple signing private keys.
- Do not disable App Attest, weaken TLS, or add a production development-bypass path to make tests pass.
- Do not send RevenueCat IDs or email addresses unless the host app intentionally chooses to provide them.

## Before editing a host app

Confirm or discover from its existing configuration:

1. Tagged BuildThisPlease SDK version.
2. Dashboard-issued publishable project key.
3. Base URL, normally `https://feedback.keinois.com`.
4. Debug and Release bundle identifiers.
5. Apple Team ID and App Attest entitlement for each configuration.
6. Host app's long-lived dependency pattern.
7. Menu or settings row that should open feedback.
8. Whether RevenueCat status, App User ID, or support email should be supplied.

If a missing value would change the target project or production identity, stop and ask rather than guessing.

## Integration rules

- Add `https://github.com/rosday/BuildThisPleaseSDK` using a semantic version tag.
- Prefer the aggregate `BuildThisPlease` product unless the app intentionally needs only Core or UI.
- Create one long-lived `BuildThisPleaseClient` per project. Never instantiate it in `body` or on every navigation.
- Use `BuildThisPlease.FeedbackListView(client:)` inside an existing `NavigationStack`.
- Use `BuildThisPlease.StandaloneFeedbackView(client:)` only when the destination needs its own navigation stack.
- Match the host app's architecture and dependency injection; do not introduce a global singleton only for this SDK.
- Use `MockBuildThisPleaseClient` in previews, UI tests, and Simulator-only workflows.
- Debug physical-device builds normally use a `development` entitlement and `.staging(baseURL: productionURL)`.
- Release/TestFlight builds must use a `production` entitlement and `.production(baseURL: productionURL)`.
- Ensure both exact app identities are registered in the dashboard before testing.
- Update the retained client when subscription status or optional support identity changes.
- Keep host-owned navigation labels localized in the host app. The package localizes strings it owns.

## Do not ship the example app

`Examples/BuildThisPleaseExample` is a development harness, not a Swift package target or product. Do not copy it into a host target, add it as a dependency, or include its mock configuration in production.

## Required verification

For SDK changes, run:

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

For host-app integration, also build the affected Debug scheme. When a connected test device is available and the user requests it, install and launch it there. A successful Simulator build does not verify App Attest.

Before declaring production readiness, confirm the checklist in `Documentation/Integration.md` and test the live flow on a physical device.
