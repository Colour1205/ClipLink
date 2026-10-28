package io.uaena.cliplink.engine

/**
 * Whether hearing a device's beacon is a reason to dial it: only when this
 * device trusts it and is not connected to it yet. A stranger is never dialled
 * for beaconing, however often it does: it reaches this device by dialling in
 * (and being asked about), by a code or link, or by an address typed in - and
 * once the user taps Trust on it in the Devices list it is a trusted device,
 * dialled like any other.
 */
internal fun dialsOnBeacon(trusted: Boolean, connected: Boolean): Boolean = trusted && !connected
