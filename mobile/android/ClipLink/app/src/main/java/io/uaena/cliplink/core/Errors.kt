package io.uaena.cliplink.core

/**
 * "IOException: Connection reset" - the class and a short, one-line message:
 * what goes in the Activity log when something fails. The class matters as
 * much as the message (a `SocketTimeoutException` and a `StackOverflowError`
 * say different things), and a message can be anything a peer made it, so it
 * is cut short.
 */
fun describeError(error: Throwable): String {
    val message = error.message?.replace('\n', ' ')?.replace('\r', ' ')?.take(120)
    val name = error.javaClass.simpleName.ifEmpty { error.javaClass.name }
    return if (message.isNullOrBlank()) name else "$name: $message"
}
