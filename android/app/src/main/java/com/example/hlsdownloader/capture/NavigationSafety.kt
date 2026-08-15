package com.example.hlsdownloader.capture

import com.example.hlsdownloader.core.AutomaticNavigationPolicy
import okhttp3.HttpUrl

/**
 * Applies the same public-to-private navigation policy to WebView capture as
 * the native HTML crawler. Keeping one implementation prevents the two
 * discovery paths from disagreeing on obfuscated IPv4/IPv6 host forms.
 */
internal object NavigationSafety {
    fun isAllowed(root: HttpUrl, target: HttpUrl): Boolean =
        AutomaticNavigationPolicy.isAllowedFrameNavigation(root, target)

    fun isPrivateOrLocal(url: HttpUrl): Boolean =
        AutomaticNavigationPolicy.isPrivateOrLocal(url)
}
