package com.example.mapx

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.android.FlutterActivity
import io.github.sceneview.ar.ArSceneView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.sqrt

class MainActivity : FlutterActivity(), SensorEventListener {
    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode {
        return FlutterActivityLaunchConfigs.BackgroundMode.transparent
    }


    private val methodChannelName = "mapx/arcore"
    private val poseChannelName = "mapx/arcore_pose"
    private val cameraPermissionCode = 100

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var sensorManager: SensorManager? = null
    private var rotationVectorSensor: Sensor? = null
    private var gameRotationVectorSensor: Sensor? = null
    private var accelerometerSensor: Sensor? = null
    private var sensorsRegistered = false

    private val rotationMatrix = FloatArray(9)
    private val gameRotationMatrix = FloatArray(9)

    // Compass heading in degrees (0 = magnetic north, clockwise). Used for
    // PDR step direction, matching how the map was recorded - never for AR
    // rendering, since the magnetometer is what makes the on-screen path
    // jitter near structural steel/electronics (see MapX AR floor-detection
    // investigation).
    @Volatile
    private var heading = 0f

    // A magnetometer-free heading for AR rendering only: TYPE_GAME_ROTATION_VECTOR
    // (gyro+accel, no magnetic field) gives a smooth frame-to-frame delta with
    // none of the compass jitter, at the cost of slowly drifting away from true
    // north over time. renderHeading tracks that smooth delta but is
    // continuously nudged back toward the real compass `heading`, capped slow
    // enough (see updateGameOrientation) that the correction is never visible
    // as a snap - a simple complementary filter.
    @Volatile
    private var renderHeading = 0f
    private var renderHeadingInitialized = false
    private var lastRawGameHeadingDeg = 0f

    // Phone tilt in degrees: ~90 held upright, ~0 lying flat.
    @Volatile
    private var tilt = 0f

    // Smoothed accelerometer oscillation: near 0 standing still, rising
    // while walking.
    @Volatile
    private var motionLevel = 0f

    private var magnitudeBaseline = SensorManager.GRAVITY_EARTH

    // ARCore floor detection state
    @Volatile
    private var floorDetected = false
    @Volatile
    private var floorHeight = 1.35f
    @Volatile
    private var cameraFovY = 60.0f
    @Volatile
    private var arTrackingState = "INITIALIZING"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkAvailability" -> checkArCoreAvailability(result)
                    "startArNavigation" -> {
                        startArNavigationMode()
                        result.success(null)
                    }
                    "stopArNavigation" -> {
                        stopArNavigationMode()
                        result.success(null)
                    }
                    "startCameraPreview" -> {
                        startCameraPreviewMode()
                        result.success(null)
                    }
                    "stopCameraPreview" -> {
                        stopCameraPreviewMode()
                        result.success(null)
                    }
                    "startSession" -> {
                        startArSessionFlow()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, poseChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    private fun checkArCoreAvailability(result: MethodChannel.Result) {
        val availability = ArCoreApk.getInstance().checkAvailability(this)
        if (availability.isTransient) {
            mainHandler.postDelayed({ checkArCoreAvailability(result) }, 200)
        } else {
            result.success(availability.name)
        }
    }

    private fun startArSessionFlow() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.CAMERA), cameraPermissionCode
            )
        } else {
            setupArSession()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == cameraPermissionCode &&
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            setupArSession()
            if (pendingCameraPreview) {
                pendingCameraPreview = false
                startCameraPreviewMode()
            }
        } else {
            pendingCameraPreview = false
            eventSink?.error("PERMISSION_DENIED", "Camera permission is required for AR tracking", null)
        }
    }

    private fun setupArSession() {
        // MAPPING / NAV PHASE: Sensors drive the live position & heading
        setupSensors()
        // startSession is called once per navigation/mapping run; without this
        // each call would stack another 30fps loop on top of the running one.
        if (poseLoopRunning) return
        poseLoopRunning = true
        mainHandler.postDelayed(object : Runnable {
            override fun run() {
                val data = mapOf(
                    "x" to 0f, "y" to 0f, "z" to 0f,
                    "tracking" to true,
                    "heading" to heading,
                    "renderHeading" to renderHeading,
                    "tilt" to tilt,
                    "motion" to motionLevel,
                    "timestamp" to System.nanoTime(),
                    "features" to 100, // Dummy value
                    "floorDetected" to floorDetected,
                    "floorHeight" to floorHeight.toDouble(),
                    "cameraFovY" to cameraFovY.toDouble(),
                    "arTrackingState" to arTrackingState
                )
                eventSink?.success(data)
                if (sensorsRegistered) {
                    mainHandler.postDelayed(this, 33) // ~30fps
                } else {
                    poseLoopRunning = false
                }
            }
        }, 33)
    }

    private var arSceneView: ArSceneView? = null
    private var poseLoopRunning = false

    // Sensor-only AR navigation: a plain CameraX preview behind the Flutter
    // overlay, with no ARCore session (so no floor detection or SLAM). The
    // line is projected from sensor heading/tilt and an assumed camera height.
    private var cameraPreviewView: PreviewView? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var pendingCameraPreview = false

    private fun startCameraPreviewMode() {
        if (cameraPreviewView != null) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // startSession has already asked; resume once it's granted.
            pendingCameraPreview = true
            return
        }

        floorDetected = false
        arTrackingState = "NONE"
        computeBackCameraVerticalFov()?.let { cameraFovY = it }

        val view = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        cameraPreviewView = view
        findViewById<android.view.ViewGroup>(android.R.id.content).addView(
            view, 0,
            android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            // Stopped again before the provider was ready.
            if (cameraPreviewView !== view) return@addListener
            try {
                val provider = providerFuture.get()
                cameraProvider = provider
                val preview = Preview.Builder().build()
                preview.setSurfaceProvider(view.surfaceProvider)
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview)
            } catch (e: Exception) {
                eventSink?.error("CAMERA_FAILED", e.message ?: "Could not open camera", null)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun stopCameraPreviewMode() {
        pendingCameraPreview = false
        cameraProvider?.unbindAll()
        cameraProvider = null
        cameraPreviewView?.let {
            findViewById<android.view.ViewGroup>(android.R.id.content).removeView(it)
        }
        cameraPreviewView = null
    }

    // Vertical FOV of the portrait preview = the sensor's long side, since
    // FILL_CENTER on a tall screen only crops the width.
    private fun computeBackCameraVerticalFov(): Float? {
        try {
            val manager = getSystemService(CAMERA_SERVICE) as CameraManager
            for (id in manager.cameraIdList) {
                val c = manager.getCameraCharacteristics(id)
                if (c.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK) continue
                val size = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: continue
                val focal = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: continue
                val longSide = maxOf(size.width, size.height)
                val fov = (2.0 * Math.atan((longSide / (2.0f * focal)).toDouble()) * 180.0 / Math.PI).toFloat()
                if (fov in 40.0f..90.0f) return fov
            }
        } catch (_: Exception) {}
        return null
    }

    private fun stopArNavigationMode() {
        floorDetected = false
        arTrackingState = "STOPPED"
        arSceneView?.let { sceneView ->
            lifecycle.removeObserver(sceneView)
            val rootView = findViewById<android.view.ViewGroup>(android.R.id.content)
            rootView.removeView(sceneView)
            sceneView.destroy()
        }
        arSceneView = null
    }

    // ARCore floor detection and anchoring:
    // ArSceneView actively scans for HORIZONTAL_UPWARD_FACING planes (the floor)
    // and tests camera-to-floor distance & FOV to anchor the navigation line
    // precisely to the physical ground.
    private fun startArNavigationMode() {
        if (arSceneView != null) return

        floorDetected = false
        arTrackingState = "INITIALIZING"

        arSceneView = ArSceneView(this).apply {
            planeFindingMode = Config.PlaneFindingMode.HORIZONTAL
            planeRenderer.isVisible = true
            planeRenderer.isEnabled = true

            onArFrame = { arFrame ->
                val camera = arFrame.camera
                val state = camera.trackingState
                arTrackingState = state.name

                if (state == TrackingState.TRACKING) {
                    // 1. Try hit-test near the center-bottom of the viewport
                    val w = width.toFloat()
                    val h = height.toFloat()
                    val hitX = if (w > 0) w * 0.5f else 500f
                    val hitY = if (h > 0) h * 0.7f else 1000f

                    var foundFloor = false
                    val hit = arFrame.hitTest(hitX, hitY)
                    if (hit != null) {
                        val trackable = hit.trackable
                        if (trackable is Plane &&
                            trackable.type == Plane.Type.HORIZONTAL_UPWARD_FACING &&
                            trackable.trackingState == TrackingState.TRACKING
                        ) {
                            val camPose = camera.pose
                            val hitPose = hit.hitPose
                            val diff = camPose.ty() - hitPose.ty()
                            if (diff in 0.3f..3.0f) {
                                floorHeight = floorHeight * 0.9f + diff * 0.1f
                                foundFloor = true
                            }
                        }
                    }

                    // 2. Fallback: query all active horizontal upward planes
                    if (!foundFloor) {
                        val planes = arFrame.session.getAllTrackables(Plane::class.java)
                        val validFloorPlanes = planes.filter {
                            it.type == Plane.Type.HORIZONTAL_UPWARD_FACING &&
                            it.trackingState == TrackingState.TRACKING
                        }
                        if (validFloorPlanes.isNotEmpty()) {
                            val camY = camera.pose.ty()
                            val closestPlane = validFloorPlanes.minByOrNull { abs(camY - it.centerPose.ty()) }
                            if (closestPlane != null) {
                                val diff = camY - closestPlane.centerPose.ty()
                                if (diff in 0.3f..3.0f) {
                                    floorHeight = floorHeight * 0.9f + diff * 0.1f
                                    foundFloor = true
                                }
                            }
                        }
                    }

                    floorDetected = foundFloor

                    // Compute vertical FOV from camera projection matrix
                    try {
                        val projMatrix = FloatArray(16)
                        camera.getProjectionMatrix(projMatrix, 0, 0.1f, 100f)
                        val p5 = projMatrix[5]
                        if (p5 > 0.0001f) {
                            val calculatedFovY = (2.0 * Math.atan(1.0 / p5.toDouble()) * 180.0 / Math.PI).toFloat()
                            if (calculatedFovY in 30.0f..100.0f) {
                                cameraFovY = cameraFovY * 0.95f + calculatedFovY * 0.05f
                            }
                        }
                    } catch (_: Exception) {}
                } else {
                    floorDetected = false
                }
            }
        }
        lifecycle.addObserver(arSceneView!!)

        val rootView = findViewById<android.view.ViewGroup>(android.R.id.content)
        rootView.addView(arSceneView, 0, android.view.ViewGroup.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            android.view.ViewGroup.LayoutParams.MATCH_PARENT
        ))
    }

    private fun setupSensors() {
        if (sensorManager == null) {
            sensorManager = getSystemService(SENSOR_SERVICE) as SensorManager
            rotationVectorSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            gameRotationVectorSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            accelerometerSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            if (rotationVectorSensor == null) {
                eventSink?.error(
                    "HEADING_SENSOR_UNAVAILABLE",
                    "This device has no rotation vector sensor",
                    null
                )
            }
        }
        registerSensors()
    }

    private fun registerSensors() {
        if (sensorsRegistered) return
        val manager = sensorManager ?: return
        rotationVectorSensor?.let {
            manager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        gameRotationVectorSensor?.let {
            manager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        accelerometerSensor?.let {
            manager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        sensorsRegistered = true
    }

    private fun unregisterSensors() {
        if (!sensorsRegistered) return
        sensorManager?.unregisterListener(this)
        sensorsRegistered = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> updateOrientation(event)
            Sensor.TYPE_GAME_ROTATION_VECTOR -> updateGameOrientation(event)
            Sensor.TYPE_ACCELEROMETER -> updateMotion(event)
        }
    }

    // Walking makes total acceleration oscillate; holding the phone still
    // keeps it steady whichever way the phone is turned. Reading that
    // oscillation owes nothing to ARCore, so VIO drift cannot fake it.
    private fun updateMotion(event: SensorEvent) {
        val magnitude = sqrt(
            event.values[0] * event.values[0] +
                event.values[1] * event.values[1] +
                event.values[2] * event.values[2]
        )
        // Measured against the phone's own resting reading rather than a
        // hardcoded 9.81: accelerometers carry a small calibration offset
        // that would otherwise register as permanent motion. Adapts far
        // slower than a walking stride, so real steps still show through.
        magnitudeBaseline = magnitudeBaseline * 0.999f + magnitude * 0.001f
        val deviation = abs(magnitude - magnitudeBaseline)
        motionLevel = motionLevel * 0.9f + deviation * 0.1f
    }

    // Computes compass heading and tilt directly from the camera-facing
    // direction (the rotation matrix's third column) instead of decomposing
    // the matrix into yaw/pitch/roll Euler angles via remapCoordinateSystem +
    // getOrientation(). Euler decomposition is only numerically stable away
    // from a pitch = +-90 deg gimbal singularity - and MapX's AR view is
    // normally held tilted down toward the floor, close enough to that
    // singularity that heading for the *same* physical orientation could
    // come out differently depending on the exact tilt at the moment (seen
    // as the AR path not returning to the same spot after panning away and
    // back). The camera-forward vector has no such singularity except when
    // the phone points exactly straight up or down, which doesn't happen in
    // normal use.
    private fun headingAndTiltFromMatrix(r: FloatArray): Pair<Float, Float> {
        // Device -Z axis (out the back, where the camera points), expressed
        // in East-North-Up world coordinates - the third column of r.
        val east = -r[2]
        val north = -r[5]
        val up = -r[8]

        val headingDeg = (Math.toDegrees(Math.atan2(east.toDouble(), north.toDouble())).toFloat() + 360f) % 360f

        // 0 deg = aiming at the horizon (old "tilt = 90"), 90 deg = aiming
        // straight down or up (old "tilt = 0").
        val pitchFromHorizontalDeg = Math.toDegrees(Math.asin(up.toDouble().coerceIn(-1.0, 1.0))).toFloat()
        val tiltDeg = 90f - abs(pitchFromHorizontalDeg)

        return Pair(headingDeg, tiltDeg)
    }

    private fun updateOrientation(event: SensorEvent) {
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
        val (headingDeg, tiltDeg) = headingAndTiltFromMatrix(rotationMatrix)
        heading = headingDeg
        tilt = tiltDeg
    }

    private fun updateGameOrientation(event: SensorEvent) {
        SensorManager.getRotationMatrixFromVector(gameRotationMatrix, event.values)
        val (rawGameHeadingDeg, _) = headingAndTiltFromMatrix(gameRotationMatrix)

        if (!renderHeadingInitialized) {
            renderHeading = heading
            lastRawGameHeadingDeg = rawGameHeadingDeg
            renderHeadingInitialized = true
            return
        }

        // This frame's smooth, magnetometer-free rotation, applied as a delta
        // so only the *change* since last frame comes from the game vector -
        // its absolute heading isn't referenced to true north at all.
        var delta = rawGameHeadingDeg - lastRawGameHeadingDeg
        if (delta > 180f) delta -= 360f
        if (delta < -180f) delta += 360f
        renderHeading = (renderHeading + delta + 360f) % 360f
        lastRawGameHeadingDeg = rawGameHeadingDeg

        // Slowly pull renderHeading back toward the true compass heading so
        // it doesn't drift indefinitely, capped small enough per sample that
        // the correction is never visible as a snap.
        var correction = heading - renderHeading
        if (correction > 180f) correction -= 360f
        if (correction < -180f) correction += 360f
        val maxCorrectionPerSample = 0.05f
        correction = correction.coerceIn(-maxCorrectionPerSample, maxCorrectionPerSample)
        renderHeading = (renderHeading + correction + 360f) % 360f
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun onResume() {
        super.onResume()
        registerSensors()
    }

    override fun onPause() {
        super.onPause()
        unregisterSensors()
    }

    override fun onDestroy() {
        unregisterSensors()
        super.onDestroy()
    }
}
