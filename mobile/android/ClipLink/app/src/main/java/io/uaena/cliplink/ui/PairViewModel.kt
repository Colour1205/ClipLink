package io.uaena.cliplink.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * What the Pair screen's "Connect" is doing, kept across an Activity
 * recreation (a rotation, a dark-mode or language switch).
 *
 * Dialling a typed-in address takes a while, and it used to run in the
 * Activity's own scope with its status in plain `remember`: a rotation
 * mid-connect cancelled the dial half way and dropped its result, leaving
 * either nothing or a "Connecting…" that never resolved. Here the dial belongs
 * to this ViewModel, so it finishes and its answer lands in the recreated
 * screen.
 */
class PairViewModel : ViewModel() {

    private val _status = MutableStateFlow("")
    val status: StateFlow<String> = _status

    /** Counts the dials, so a slow earlier one can't overwrite the answer to a later one. */
    private var latest = 0

    fun pair(raw: String, pairWith: suspend (String) -> String) {
        val mine = ++latest
        _status.value = "Connecting…"
        viewModelScope.launch {
            val result = try {
                pairWith(raw)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                "Couldn't connect: ${e.message ?: e.javaClass.simpleName}."
            }
            if (mine == latest) _status.value = result
        }
    }

    fun clear() {
        latest++
        _status.value = ""
    }
}
