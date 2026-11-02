plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.sixbit.pubsubpush"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.sixbit.pubsubpush"
        minSdk = 30 // pushDynamicShortcut (conversation notifications); GrapheneOS devices are far newer
        targetSdk = 36
        versionCode = 6
        versionName = "0.2.2"
    }

    // A stable key, so rebuilds install as updates. Kept outside git
    // (android/signing/, gitignored); without it Gradle's per-home debug key
    // is used, which changes whenever that home is rebuilt. Kept encrypted in
    // secrets/signing.yaml (sops: josh, ada); `restore-signing-key` in the
    // android devShell puts it here.
    val keystore = rootProject.file("signing/pubsub-push.keystore")
    signingConfigs {
        if (keystore.exists()) {
            create("stable") {
                storeFile = keystore
                storePassword = "pubsub-push"
                keyAlias = "pubsub-push"
                keyPassword = "pubsub-push"
            }
        }
    }

    buildTypes {
        debug {
            signingConfigs.findByName("stable")?.let { signingConfig = it }
        }
        release {
            isMinifyEnabled = false
            signingConfigs.findByName("stable")?.let { signingConfig = it }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // Framework APIs only otherwise (no AndroidX): keeps the dependency set
    // small for a pure Nix build later.
    implementation("org.unifiedpush.android:connector:3.3.5")
}
