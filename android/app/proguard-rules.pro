# google_mlkit_text_recognition declares every script recogniser it supports,
# but this app only bundles the Latin one (see pubspec). R8 therefore sees
# references to the Chinese / Devanagari / Japanese / Korean option classes
# with nothing to resolve them against and fails the release build. The app
# never asks for those scripts, so the references are dead code - silence them
# rather than pulling in four more ML Kit models.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
