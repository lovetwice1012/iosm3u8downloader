package com.example.hlsdownloader.capture

import android.content.Context
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/**
 * Owns the normal on-disk WebView profile used by both visible and fallback
 * capture sessions. Session teardown only flushes this profile; deletion is an
 * explicit user action routed through [clearAllData].
 */
object PersistentWebProfile {
    @Suppress("DEPRECATION")
    fun configureStorage(view: WebView) {
        view.settings.apply {
            domStorageEnabled = true
            databaseEnabled = true
            cacheMode = WebSettings.LOAD_DEFAULT
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(view, true)
        }
    }

    fun flushCookies() {
        CookieManager.getInstance().flush()
    }

    /**
     * Clears the shared profile only after an explicit confirmation in the UI.
     * The caller must ensure that no capture WebView is active.
     */
    @Suppress("DEPRECATION")
    suspend fun clearAllData(context: Context): Boolean = withContext(Dispatchers.Main.immediate) {
        val applicationContext = context.applicationContext
        val removedCookies = suspendCancellableCoroutine { continuation ->
            CookieManager.getInstance().removeAllCookies { removed ->
                if (continuation.isActive) continuation.resume(removed)
            }
        }
        flushCookies()

        WebStorage.getInstance().deleteAllData()
        GeolocationPermissions.getInstance().clearAll()
        WebViewDatabase.getInstance(applicationContext).apply {
            clearFormData()
            clearHttpAuthUsernamePassword()
        }

        // clearCache(true) is scoped to the shared WebView profile, not only
        // this temporary instance. No history or form data leaves this object.
        WebView(applicationContext).apply {
            clearCache(true)
            clearHistory()
            clearFormData()
            clearSslPreferences()
            destroy()
        }
        WebView.clearClientCertPreferences(null)
        removedCookies
    }
}
