package io.uaena.cliplink.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors

// Reused across frames rather than allocated per-frame - safe because
// analysis.setAnalyzer runs on a single-thread executor, so decodeQr is
// never called concurrently.
private val qrReader = MultiFormatReader()

/**
 * Camera-based QR scanner for pairing. Decodes via zxing-core (already a
 * dependency for QrPanel's own display side) rather than pulling in a
 * second barcode library - the only new piece here is feeding CameraX
 * frames into it.
 */
@Composable
fun ScanScreen(
    contentPadding: PaddingValues,
    onBack: () -> Unit,
    onResult: (String) -> Unit,
    /** The camera can't be used (none, blocked, or CameraX failed): [message] says so; the caller leaves this screen. */
    onUnavailable: (message: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    // Read from the system - and again whenever the app resumes, so coming
    // back from the settings page with the permission turned on just works.
    val grantedInSystem = rememberPermissionGranted(Manifest.permission.CAMERA)
    var grantedByDialog by remember { mutableStateOf(false) }
    val hasPermission = grantedInSystem || grantedByDialog
    // Camera-less devices can install this app (camera.any is not required).
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    // Set when the system refused without asking: after a "don't ask again" (or
    // the second refusal) the dialog never shows again, and the request button
    // did nothing at all - the only way left is the app's settings page.
    var permanentlyDenied by rememberSaveable { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        grantedByDialog = granted
        if (!granted) {
            val activity = context.findActivity()
            permanentlyDenied = activity == null ||
                !ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.CAMERA)
        }
    }

    Column(
        modifier
            .fillMaxSize()
            .padding(
                start = 16.dp,
                end = 16.dp,
                top = contentPadding.calculateTopPadding(),
                bottom = contentPadding.calculateBottomPadding() + 32.dp,
            ),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(top = 8.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Spacer(Modifier.width(4.dp))
            Text(
                "Scan a device's code",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }

        Spacer(Modifier.height(20.dp))

        if (!hasCamera) {
            UnavailableCard(
                "This device has no camera to scan with. Go back and use \"Pair by address\" instead.",
            )
        } else if (hasPermission) {
            CameraPreview(onResult = onResult, onUnavailable = { onUnavailable(CAMERA_UNAVAILABLE_MESSAGE) })
            Spacer(Modifier.height(16.dp))
            Text(
                "Point the camera at the other device's pairing code. Its own pairing screen " +
                    "has to be open too - a scan alone can't trust it.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Surface(
                shape = RoundedCornerShape(28.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    Modifier.padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        Icons.Filled.CameraAlt,
                        contentDescription = null,
                        modifier = Modifier.padding(bottom = 12.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        if (permanentlyDenied) {
                            "Camera access is turned off for ClipLink. Turn it on in the app's " +
                                "settings to scan a code."
                        } else {
                            "Camera access is needed to scan a code."
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.height(16.dp))
                    if (permanentlyDenied) {
                        Button(onClick = { openAppSettings(context) }) { Text("Open app settings") }
                    } else {
                        Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) {
                            Text("Grant camera access")
                        }
                    }
                }
            }
        }
    }
}

private const val CAMERA_UNAVAILABLE_MESSAGE =
    "The camera isn't available right now. You can still pair by address."

@Composable
private fun UnavailableCard(message: String) {
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                Icons.Filled.CameraAlt,
                contentDescription = null,
                modifier = Modifier.padding(bottom = 12.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/** What the camera screen's async callbacks need to reach: the provider to release, and whether the screen is gone. */
private class CameraBinding {
    var provider: ProcessCameraProvider? = null
    var disposed = false
}

@Composable
private fun CameraPreview(onResult: (String) -> Unit, onUnavailable: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // rememberUpdatedState so the analyzer (set up once, in the
    // AndroidView factory below) always calls the LATEST onResult lambda,
    // not a stale one captured at first composition.
    val currentOnResult by rememberUpdatedState(onResult)
    val currentOnUnavailable by rememberUpdatedState(onUnavailable)
    // Guards against firing onResult more than once - frames keep arriving
    // (and keep decoding successfully) for as long as the camera stays
    // bound after a hit, and the caller only expects a single callback.
    var resultDelivered by remember { mutableStateOf(false) }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    // bindToLifecycle ties the use cases to the ACTIVITY's lifecycle, not
    // to this composable's presence - ScanScreen gets unmounted via
    // ClipLinkApp's AnimatedContent (a plain state change), not an
    // Activity stop/start, so without explicitly unbinding here the
    // camera stays bound and streaming after the user backs out: held
    // hardware, drained battery, the camera-in-use indicator staying lit
    // until the screen happens to be reopened (whose factory unbinds
    // first) or the app backgrounds. Not remembered STATE - this only
    // exists for onDispose and the async listener to reach into, never
    // read during composition.
    //
    // `disposed` is the other half: CameraX's provider arrives
    // asynchronously, so a user who backs out before it does used to get
    // nothing unbound (the provider wasn't known yet), the executor shut
    // down, and then the listener binding the camera anyway - left on, with
    // the privacy indicator lit, until the app was backgrounded.
    val binding = remember { CameraBinding() }
    val mainExecutor = remember { ContextCompat.getMainExecutor(context) }

    DisposableEffect(Unit) {
        onDispose {
            binding.disposed = true
            analysisExecutor.shutdown()
            runCatching { binding.provider?.unbindAll() }
        }
    }

    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(24.dp)),
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    val previewView = PreviewView(ctx)

                    // The camera can't be had: say so and let the caller leave.
                    // Posted rather than called, as this may run during composition.
                    fun fail() = mainExecutor.execute { if (!binding.disposed) currentOnUnavailable() }

                    val cameraProviderFuture = try {
                        ProcessCameraProvider.getInstance(ctx)
                    } catch (e: Exception) {
                        fail()
                        return@AndroidView previewView
                    }
                    cameraProviderFuture.addListener({
                        // Backed out before CameraX was ready: nothing to start.
                        if (binding.disposed) return@addListener

                        // get() throws when CameraX failed to initialise - no
                        // camera, one blocked by policy - and in a main-executor
                        // callback that was an uncaught exception: the app died.
                        val cameraProvider = try {
                            cameraProviderFuture.get()
                        } catch (e: Exception) {
                            fail()
                            return@addListener
                        }
                        binding.provider = cameraProvider

                        try {
                            val preview = Preview.Builder().build().also {
                                it.surfaceProvider = previewView.surfaceProvider
                            }

                            val analysis = ImageAnalysis.Builder()
                                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                .build()
                            analysis.setAnalyzer(analysisExecutor) { imageProxy ->
                                decodeQr(imageProxy)?.let { text ->
                                    if (!resultDelivered) {
                                        resultDelivered = true
                                        // On the main thread, like everything this
                                        // callback ends up touching.
                                        mainExecutor.execute { currentOnResult(text) }
                                    }
                                }
                            }

                            cameraProvider.unbindAll()
                            cameraProvider.bindToLifecycle(
                                lifecycleOwner,
                                CameraSelector.DEFAULT_BACK_CAMERA,
                                preview,
                                analysis,
                            )
                        } catch (e: Exception) {
                            // In use by another app, none on this device, or
                            // blocked: release what was started, and say so -
                            // a silent black square read as a hang.
                            runCatching { cameraProvider.unbindAll() }
                            fail()
                        }
                    }, mainExecutor)
                    previewView
                },
            )
        }
    }
}

/**
 * Reads the Y (luma) plane straight out of the frame - QR decoding only
 * needs luminance, not full YUV_420_888 color conversion, which is what
 * makes this cheap enough to run on every frame from a single-thread
 * executor. Returns null (not just on a decode miss, which is the expected
 * common case every frame without a code in view, but also on any
 * unexpected error) - never throws out of an analyzer callback.
 */
private fun decodeQr(imageProxy: ImageProxy): String? {
    try {
        val plane = imageProxy.planes[0]
        val buffer = plane.buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)

        // dataWidth has to be the Y-plane's actual ROW STRIDE, not the
        // image's pixel width - YUV_420_888 output is allowed to pad each
        // row (rowStride > width) on some devices/resolutions, and using
        // the unpadded width here would silently misalign every row past
        // the first, making the decoder essentially never find a real
        // code on any device that happens to pad. The crop rect below
        // (0, 0, width, height) is still the true image size - that's
        // what excludes the padding bytes from actually being scanned.
        val source = PlanarYUVLuminanceSource(
            bytes,
            plane.rowStride,
            imageProxy.height,
            0,
            0,
            imageProxy.width,
            imageProxy.height,
            false,
        )
        val bitmap = BinaryBitmap(HybridBinarizer(source))
        return qrReader.decode(bitmap).text
    } catch (e: NotFoundException) {
        return null // no QR code in this frame - the normal case
    } catch (e: Exception) {
        return null
    } finally {
        imageProxy.close()
    }
}
