// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.compose.compiler) apply false
}

// This repository lives under a OneDrive-synced folder, and OneDrive treats
// build/ like any other content: it opens and re-uploads the intermediates
// while Gradle is still writing them. The result is a build that fails
// intermittently with "Unable to delete directory ... a process has files
// open", on directories nothing in the build is actually using - most often
// merged_res_blame_folder and the Kotlin incremental caches.
//
// Redirecting the build output outside the synced tree fixes it outright, and
// stops OneDrive uploading a gigabyte of regenerable intermediates. The
// redirect only engages when the project genuinely is inside a OneDrive
// folder, so moving this repo elsewhere silently restores the normal
// ./app/build layout with no config change.
//
// Override the destination with -Pcliplink.buildRoot=<path> if needed.
//
// The default is a fixed per-user folder, NOT java.io.tmpdir: that comes from
// whichever Gradle daemon runs the build, and Android Studio reuses a daemon a
// command-line build started with a different TEMP. The build then landed
// somewhere other than where the IDE looks, and Run installed a stale APK -
// seen as INSTALL_FAILED_NO_MATCHING_ABIS from an old emulator-only build.
val syncedFolderNames = listOf("onedrive", "dropbox", "google drive", "icloud")
val projectPath = rootDir.absolutePath.replace('\\', '/').lowercase()
val insideSyncedFolder = syncedFolderNames.any { projectPath.contains("/$it") }

if (insideSyncedFolder) {
    val defaultBuildRoot = System.getenv("LOCALAPPDATA")?.let { "$it/cliplink-build" }
        ?: "${System.getProperty("user.home")}/.cliplink-build"
    val buildRoot = providers.gradleProperty("cliplink.buildRoot").orNull ?: defaultBuildRoot
    allprojects {
        layout.buildDirectory.set(file("$buildRoot/${rootProject.name}/${project.name}"))
    }
    logger.lifecycle("ClipLink: build output redirected to $buildRoot (project is inside a synced folder)")
}
