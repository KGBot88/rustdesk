package com.carriez.flutter_hbb

/**
 * Gamepad bridge (rustdesk-controller fork).
 *
 * While a remote session is open (Dart sends "set_active" true), controller input is
 * taken here, before Flutter or Android see it, and forwarded to Dart:
 *   - "axes": [lx, ly, rx, ry, lt, rt, hatX, hatY]  (only when something changed)
 *   - "key":  {code: <Android keycode>, down: <bool>}
 * Consuming the events stops controller buttons (e.g. B -> Back) from reaching
 * Android navigation. Outside a session nothing is intercepted.
 */

import android.content.Context
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.widget.FrameLayout
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.max

object GamepadBridge {
    private const val TAG = "RdGamepad"
    private var channel: MethodChannel? = null

    @Volatile
    var active = false
        private set

    /** Controller-mouse mode (Dart "set_mode"). Off = pad is inert on the PC; B/Back act as Android Back. */
    @Volatile
    var mappingOn = true
        private set

    /** Android Back action, set by MainActivity. */
    var onBack: (() -> Unit)? = null

    /** Force the soft keyboard to show (Dart "force_ime"), set by MainActivity. */
    var onForceIme: (() -> Unit)? = null

    /** Make the soft keyboard re-read the text field (Dart "ime_restart"), set by MainActivity. */
    var onImeRestart: (() -> Unit)? = null

    private val last = FloatArray(8)
    private val loggedDevices = HashSet<Int>()

    fun attach(ch: MethodChannel) {
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "set_mode" -> {
                    mappingOn = call.arguments as? Boolean ?: true
                    last.fill(0f)
                    Log.i(TAG, "mappingOn=$mappingOn")
                    result.success(true)
                }
                "force_ime" -> {
                    onForceIme?.invoke()
                    result.success(true)
                }
                "ime_restart" -> {
                    onImeRestart?.invoke()
                    result.success(true)
                }
                "set_active" -> {
                    active = call.arguments as? Boolean ?: false
                    last.fill(0f)
                    Log.i(TAG, "active=$active")
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isPadDevice(dev: InputDevice?): Boolean {
        if (dev == null || dev.isVirtual) return false
        val s = dev.sources
        return (s and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD ||
            (s and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK
    }

    private fun logDevice(dev: InputDevice) {
        if (!loggedDevices.add(dev.id)) return
        val axes = dev.motionRanges.joinToString(",") { MotionEvent.axisToString(it.axis) }
        Log.i(TAG, "device '${dev.name}' id=${dev.id} sources=0x${Integer.toHexString(dev.sources)} axes=[$axes]")
    }

    private fun has(dev: InputDevice, axis: Int) =
        dev.getMotionRange(axis, InputDevice.SOURCE_JOYSTICK) != null

    /** Returns true when the event was consumed. */
    fun onMotion(ev: MotionEvent): Boolean {
        if (!active) return false
        if ((ev.source and InputDevice.SOURCE_JOYSTICK) != InputDevice.SOURCE_JOYSTICK) return false
        if (ev.actionMasked != MotionEvent.ACTION_MOVE) return false
        val dev = ev.device ?: return false
        logDevice(dev)
        if (!mappingOn) return true // inert: sticks/triggers/hat do nothing

        // Right stick is AXIS_Z/AXIS_RZ on standard Android mappings, AXIS_RX/AXIS_RY on some pads.
        val useZ = has(dev, MotionEvent.AXIS_Z) && has(dev, MotionEvent.AXIS_RZ)
        val v = floatArrayOf(
            ev.getAxisValue(MotionEvent.AXIS_X),
            ev.getAxisValue(MotionEvent.AXIS_Y),
            ev.getAxisValue(if (useZ) MotionEvent.AXIS_Z else MotionEvent.AXIS_RX),
            ev.getAxisValue(if (useZ) MotionEvent.AXIS_RZ else MotionEvent.AXIS_RY),
            max(ev.getAxisValue(MotionEvent.AXIS_LTRIGGER), ev.getAxisValue(MotionEvent.AXIS_BRAKE)),
            max(ev.getAxisValue(MotionEvent.AXIS_RTRIGGER), ev.getAxisValue(MotionEvent.AXIS_GAS)),
            ev.getAxisValue(MotionEvent.AXIS_HAT_X),
            ev.getAxisValue(MotionEvent.AXIS_HAT_Y),
        )
        var changed = false
        for (i in v.indices) {
            if (abs(v[i] - last[i]) > 0.004f) changed = true
        }
        if (changed) {
            System.arraycopy(v, 0, last, 0, v.size)
            channel?.invokeMethod("axes", v.map { it.toDouble() })
        }
        return true
    }

    /** Returns true when the event was consumed. */
    fun onKey(ev: KeyEvent): Boolean {
        if (!active) return false
        val dev = ev.device
        if (!isPadDevice(dev)) return false
        when (ev.keyCode) {
            // Leave system keys alone.
            KeyEvent.KEYCODE_HOME, KeyEvent.KEYCODE_APP_SWITCH, KeyEvent.KEYCODE_POWER,
            KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE -> return false
        }
        logDevice(dev!!)
        val code = ev.keyCode
        val comboKey = code == KeyEvent.KEYCODE_BUTTON_SELECT || code == KeyEvent.KEYCODE_BUTTON_START
        if (!mappingOn && !comboKey) {
            // Mouse mode off: nothing goes to the PC. B and Back keep acting as Android Back.
            return when (code) {
                KeyEvent.KEYCODE_BACK -> false
                KeyEvent.KEYCODE_BUTTON_B -> {
                    if (ev.action == KeyEvent.ACTION_UP && !ev.isCanceled) onBack?.invoke()
                    true
                }
                else -> true
            }
        }
        if (ev.action == KeyEvent.ACTION_DOWN && ev.repeatCount > 0) return true // Dart does its own repeat
        if (ev.action != KeyEvent.ACTION_DOWN && ev.action != KeyEvent.ACTION_UP) return true
        channel?.invokeMethod(
            "key",
            mapOf("code" to ev.keyCode, "down" to (ev.action == KeyEvent.ACTION_DOWN))
        )
        return true
    }
}

/**
 * Wraps the Flutter view so controller buttons are taken in the pre-IME stage.
 * Without it, an open soft keyboard (Gboard) swallows gamepad buttons before
 * Activity.dispatchKeyEvent runs, so Y couldn't close the keyboard and B/L1/R1 did nothing.
 */
class GamepadPreImeFrame(context: Context) : FrameLayout(context) {
    override fun dispatchKeyEventPreIme(event: KeyEvent): Boolean {
        if (GamepadBridge.onKey(event)) return true
        return super.dispatchKeyEventPreIme(event)
    }
}
