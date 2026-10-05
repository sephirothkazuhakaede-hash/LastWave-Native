# Message push setup

The Android app receives account-scoped data messages and registers device tokens privately under users/{uid}/devices/{installationID}. The trigger reads existing conversation messages written by Android or iOS and sends only to the other participant's registered Android devices. It skips already-read messages and removes invalid tokens. No server credentials belong in the APK.

This trigger is supplied but is not deployed by the Android build. The current Firebase Spark project does not include a configured server sender. Cloud Functions deployment requires the project owner's billing-enabled Firebase setup; no billing plan is changed automatically.

Once an authorized owner has configured Functions, run `npm install` in this directory, then from the repository root run `firebase deploy --project capyflow-aa6c5 --only functions:capyflow-push`. The source/codebase configuration is already in firebase.json. Publish the tested device-token Firestore rules as well. Grant notification permission on Android and test delivery while the app is backgrounded. Foreground notifications already use the live inbox listener without a server sender.

The existing iOS app must separately register APNs/FCM tokens and have Apple push entitlements and server credentials before it can receive background pushes. This Android patch does not alter iOS signing or provisioning.
