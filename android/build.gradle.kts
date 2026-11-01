// AGP 8.13 needs Gradle >= 8.13 (nixpkgs: 8.14); Kotlin matches nixpkgs' kotlin.
plugins {
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.3.21" apply false
}
