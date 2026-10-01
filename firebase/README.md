# CapyFlow social setup

CapyFlow audio never depends on Firebase. Firestore stores only profiles,
follows, collaborators, and shared-playlist metadata.

The public Firestore endpoint check on 2026-10-01 initially returned
`SERVICE_DISABLED` for project `capyflow-aa6c5`. The API was enabled and the
default database was created in `asia-southeast1` (Singapore) that day. The
checked-in production rules were then published successfully.

For a new Firebase project, the owner must:

1. Enable the Cloud Firestore API in Google Cloud/Firebase Console.
2. Create the default Firestore database in a deliberately chosen location.
   The location is permanent; `asia-southeast1` (Singapore) is the nearby
   recommendation for users in the Philippines.
3. Deploy the checked-in rules and indexes from the repository root:

   ```sh
   npx firebase-tools login
   npx firebase-tools deploy --only firestore --project capyflow-aa6c5
   ```

The app turns missing/offline Firestore into a friendly, retryable social
status. It must never block streaming, cached playback, or downloads.
