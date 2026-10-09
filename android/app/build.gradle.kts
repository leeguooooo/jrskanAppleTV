import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Release signing comes from the environment in CI and from
// ~/.android-keys/jrkan-release.properties on a developer machine. Without
// either, release builds fall back to the debug key so `assembleRelease`
// still works locally — such an APK just cannot update a CI-signed install.
val signingProps = Properties().apply {
    val file = File(System.getProperty("user.home"), ".android-keys/jrkan-release.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
fun signingValue(env: String, key: String): String? = System.getenv(env) ?: signingProps.getProperty(key)

android {
    namespace = "com.leeguoo.jrkan"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.leeguoo.jrskan"
        minSdk = 26
        targetSdk = 36
        versionCode = (System.getenv("JRKAN_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("JRKAN_VERSION_NAME") ?: "1.0.0"
    }

    signingConfigs {
        val storeFile = signingValue("JRKAN_KEYSTORE", "storeFile")
        if (storeFile != null) {
            create("release") {
                this.storeFile = file(storeFile)
                storePassword = signingValue("JRKAN_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signingValue("JRKAN_KEY_ALIAS", "keyAlias")
                keyPassword = signingValue("JRKAN_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        // `-PjrkanLive=1` opts into LiveSiteContractTest (hits the real site).
        unitTests.all { test ->
            test.systemProperty("jrkan.live", project.findProperty("jrkanLive")?.toString() ?: "")
            test.testLogging { events("failed", "skipped"); showStandardStreams = false }
        }
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons.extended)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.navigation.compose)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.hls)
    implementation(libs.media3.ui)
    implementation(libs.media3.okhttp)
    implementation(libs.media3.transformer)
    implementation(libs.media3.effect)
    implementation(libs.okhttp)
    implementation(libs.coil.compose)
    implementation(libs.coil.okhttp)
    implementation(libs.rhino)
    implementation(libs.serialization.json)
    implementation(libs.coroutines.android)
    implementation(libs.browser)
    implementation(libs.core.ktx)
    debugImplementation(libs.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
