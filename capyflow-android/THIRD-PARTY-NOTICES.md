# Direct music fallback dependencies

NewPipe Extractor v0.26.5 (GPL-3.0-or-later)
https://github.com/TeamNewPipe/NewPipeExtractor/tree/v0.26.5
The app uses its local YouTube extractor; it does not require MSI for fallback streams.

Firebase protolite-well-known-types 18.0.1 (Apache-2.0)
https://maven.google.com/web/index.html#com.google.firebase:protolite-well-known-types:18.0.1
The compatible AAR in app/libs retains all Google API, RPC and other message types.
Only 101 com/google/protobuf/*.class entries already supplied by protobuf-javalite
4.35.1, plus its duplicate google/protobuf/descriptor.proto resource, were removed to avoid duplicate classes. No service behavior was changed.
The original dependency is excluded and this compatible AAR is used instead.

Other dependencies retain their upstream licenses and Gradle coordinates.
