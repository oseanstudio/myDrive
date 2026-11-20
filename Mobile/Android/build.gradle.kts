plugins {
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
}
layout.buildDirectory.set(file(System.getenv("MYDRIVE_ANDROID_BUILD")?.let { "$it/root" } ?: "${System.getProperty("user.home")}/.cache/mydrive/android/root"))
