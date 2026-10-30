package io.uaena.cliplink.ui

/**
 * What the delete and clear-all dialogs say. A delete goes to every paired device that has the new version
 * (see SyncManager.broadcastDelete); one with an older ClipLink does not hear of it and keeps its copy.
 */
internal object DeleteWording {
    const val ITEM_BODY =
        "It's deleted from this phone and from your paired devices, and won't come back. " +
            "A device with an older ClipLink keeps its copy."

    const val CLEAR_ROW = "Deletes every item from this phone and from your paired devices."

    const val CLEAR_BODY =
        "Every synced item is deleted from this phone and from your paired devices, " +
            "and won't come back. A device with an older ClipLink keeps its copies."
}
