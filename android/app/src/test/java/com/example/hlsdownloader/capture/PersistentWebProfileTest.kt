package com.example.hlsdownloader.capture

import android.content.Context
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PersistentWebProfileTest {
    @Suppress("DEPRECATION")
    @Test
    fun configuresPersistentDomDatabaseCacheAndCookies() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val webView = WebView(context)

        try {
            PersistentWebProfile.configureStorage(webView)

            assertTrue(webView.settings.domStorageEnabled)
            assertTrue(webView.settings.databaseEnabled)
            assertEquals(WebSettings.LOAD_DEFAULT, webView.settings.cacheMode)
            assertTrue(CookieManager.getInstance().acceptCookie())
        } finally {
            webView.destroy()
        }
    }
}
