plugins { id("com.android.application"); id("org.jetbrains.kotlin.android"); id("org.jetbrains.kotlin.plugin.compose") }
val firebaseConfigured = file("google-services.json").exists()
if (firebaseConfigured) apply(plugin = "com.google.gms.google-services")
android {
    namespace = "com.seph.capyflow"
    compileSdk = 36
    defaultConfig { applicationId = "com.seph.capyflow"; minSdk = 26; targetSdk = 36; versionCode = 22; versionName = "1.0.9"; buildConfigField("boolean", "FIREBASE_CONFIGURED", firebaseConfigured.toString()) }
    val ciSigning = System.getenv("CAPYFLOW_CI_KEYSTORE")
    if(ciSigning != null) signingConfigs { getByName("debug") { storeFile = file(ciSigning);storePassword="android";keyAlias="capyflow-ci";keyPassword="android" } }
    else if (rootProject.file("signing/capyflow-preview.jks").exists()) signingConfigs { getByName("debug") { storeFile = rootProject.file("signing/capyflow-preview.jks"); storePassword = "android"; keyAlias = "capyflow-preview"; keyPassword = "android" } }
    buildTypes {
        getByName("release") {
            isDebuggable = false
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions { isCoreLibraryDesugaringEnabled = true; sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
}
dependencies {
    implementation(files("libs/protolite-well-known-types-18.0.1-compatible.aar"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
    implementation("com.github.TeamNewPipe:NewPipeExtractor:v0.26.5")
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.media3:media3-exoplayer:1.6.1")
    implementation("androidx.media3:media3-session:1.6.1")
    implementation("androidx.media3:media3-datasource-okhttp:1.6.1")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("io.coil-kt:coil-gif:2.7.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation(platform("com.google.firebase:firebase-bom:33.13.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.firebase:firebase-messaging")
    implementation("com.google.android.gms:play-services-auth:21.3.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

// The local compatible AAR retains Google API/RPC types and removes only protobuf
// classes now also supplied by protobuf-javalite 4. See THIRD-PARTY-NOTICES.md.
configurations.configureEach { exclude(group = "com.google.firebase", module = "protolite-well-known-types") }
