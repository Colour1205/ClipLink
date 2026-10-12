pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "ClipLink"
include(":app")

// Redirect build directories if living inside a cloud-synced folder (e.g. OneDrive).
// Configured in settings.gradle.kts via gradle.beforeProject so AGP initializes all task outputs
// (including IDE redirect files) with the custom buildDirectory before plugins are applied.
val syncedFolderNames = listOf("onedrive", "dropbox", "google drive", "icloud")
val projectPath = rootDir.absolutePath.replace('\\', '/').lowercase()
val insideSyncedFolder = syncedFolderNames.any { projectPath.contains("/$it") }

if (insideSyncedFolder) {
    val localAppData = providers.environmentVariable("LOCALAPPDATA").orNull ?: System.getenv("LOCALAPPDATA")
    val defaultBuildRoot = localAppData?.let { "$it/cliplink-build" }
        ?: "${System.getProperty("user.home")}/.cliplink-build"
    val buildRoot = providers.gradleProperty("cliplink.buildRoot").orNull ?: defaultBuildRoot
    gradle.beforeProject {
        layout.buildDirectory.set(file("$buildRoot/${rootProject.name}/$name"))
    }
}




