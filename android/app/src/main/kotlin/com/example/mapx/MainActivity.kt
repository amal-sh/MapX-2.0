package com.example.mapx

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.UnavailableException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.abs
import kotlin.math.sqrt

class MainActivity : FlutterActivity(), SensorEventListener {
    private val methodChannelName = "mapx/arcore"
    private val poseChannelName = "mapx/arcore_pose"
    private val cameraPermissionCode = 100

    private var arSession: Session? = null
    private var glSurfaceView: GLSurfaceView? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var sensorManager: SensorManager? = null
    private var rotationVectorSensor: Sensor? = null
    private var accelerometerSensor: Sensor? = null
    private var sensorsRegistered = false

    private val rotationMatrix = FloatArray(9)
    private val remappedMatrix = FloatArray(9)
    private val orientation = FloatArray(3)

    // Compass heading in degrees (0 = magnetic north, clockwise).
    @Volatile
    private var heading = 0f

    // Phone tilt in degrees: ~90 held upright, ~0 lying flat.
    @Volatile
    private var tilt = 0f

    // Smoothed accelerometer oscillation: near 0 standing still, rising
    // while walking.
    @Volatile
    private var motionLevel = 0f

    private var magnitudeBaseline = SensorManager.GRAVITY_EARTH

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkAvailability" -> checkArCoreAvailability(result)
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
        } else {
            eventSink?.error("PERMISSION_DENIED", "Camera permission is required for AR tracking", null)
        }
    }

    private fun setupArSession() {
        if (arSession != null) return
        try {
            arSession = Session(this)
            arSession?.resume()
        } catch (e: UnavailableException) {
            eventSink?.error("AR_SESSION_ERROR", e.message, null)
            return
        } catch (e: CameraNotAvailableException) {
            eventSink?.error("CAMERA_UNAVAILABLE", e.message, null)
            arSession = null
            return
        }

        val view = GLSurfaceView(this)
        view.setEGLContextClientVersion(2)
        view.setRenderer(object : GLSurfaceView.Renderer {
            override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
                val textures = IntArray(1)
                GLES20.glGenTextures(1, textures, 0)
                arSession?.setCameraTextureName(textures[0])
            }

            override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {}

            override fun onDrawFrame(gl: GL10?) {
                val session = arSession ?: return
                try {
                    val frame = session.update()
                    val camera = frame.camera
                    val pose = camera.pose

                    // How many visual features ARCore is currently holding.
                    // TrackingState still reads TRACKING when this is low, but
                    // with little to see ARCore leans on IMU integration, which
                    // over-reports distance - so this is the honest measure of
                    // whether the position can be trusted.
                    val featurePoints = frame.acquirePointCloud().use { cloud ->
                        cloud.points.remaining() / 4
                    }
                    val data = mapOf(
                        "x" to pose.tx(),
                        "y" to pose.ty(),
                        "z" to pose.tz(),
                        "tracking" to (camera.trackingState == TrackingState.TRACKING),
                        "heading" to heading,
                        "tilt" to tilt,
                        "motion" to motionLevel,
                        // ARCore's own capture clock. Timing must not be taken
                        // from arrival time on the Flutter side: these events
                        // cross a thread boundary and arrive in bunches, which
                        // makes normal movement look impossibly fast.
                        "timestamp" to frame.timestamp,
                        "features" to featurePoints
                    )
                    mainHandler.post { eventSink?.success(data) }
                } catch (e: CameraNotAvailableException) {
                    mainHandler.post { eventSink?.error("CAMERA_UNAVAILABLE", e.message, null) }
                }
            }
        })
        view.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        addContentView(view, ViewGroup.LayoutParams(1, 1))
        glSurfaceView = view

        setupSensors()
    }

    private fun setupSensors() {
        if (sensorManager == null) {
            sensorManager = getSystemService(SENSOR_SERVICE) as SensorManager
            rotationVectorSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
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

    private fun updateOrientation(event: SensorEvent) {
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)

        // Tilt comes from the unremapped matrix, where pitch reads ~-90 with
        // the phone upright and ~0 lying flat. The heading remap below is
        // only valid while the phone is upright, so this is what tells us
        // whether the heading can be trusted.
        SensorManager.getOrientation(rotationMatrix, orientation)
        tilt = Math.abs(Math.toDegrees(orientation[1].toDouble())).toFloat()

        // The default orientation assumes the phone lies flat, screen up.
        // MapX is held upright with the camera facing forward, so the axes
        // are remapped to read the heading the camera points at.
        SensorManager.remapCoordinateSystem(
            rotationMatrix, SensorManager.AXIS_X, SensorManager.AXIS_Z, remappedMatrix
        )
        SensorManager.getOrientation(remappedMatrix, orientation)

        val degrees = Math.toDegrees(orientation[0].toDouble()).toFloat()
        heading = (degrees + 360f) % 360f
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun onResume() {
        super.onResume()
        try {
            arSession?.resume()
        } catch (e: CameraNotAvailableException) {
            eventSink?.error("CAMERA_UNAVAILABLE", e.message, null)
        }
        glSurfaceView?.onResume()
        registerSensors()
    }

    override fun onPause() {
        super.onPause()
        glSurfaceView?.onPause()
        arSession?.pause()
        unregisterSensors()
    }

    override fun onDestroy() {
        unregisterSensors()
        arSession?.close()
        arSession = null
        super.onDestroy()
    }
}
