package com.example.hlsdownloader.core

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser

data class ExtractedHtmlMedia(
    val rawUrl: String,
    val rawPosterUrl: String?,
    val title: String?,
    val origin: HlsCandidateOrigin,
)

data class ExtractedHtmlFrame(
    val rawUrl: String?,
    val sourceDocument: String?,
    val title: String?,
)

data class HtmlMediaExtraction(
    val baseHref: String?,
    val title: String?,
    val rawThumbnailUrl: String?,
    val media: List<ExtractedHtmlMedia>,
    val frames: List<ExtractedHtmlFrame>,
)

object HtmlMediaExtractor {
    private val hlsMimeTypes = setOf(
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "application/mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl",
    )
    private val m3u8Suffix = Regex("\\.m3u8(?:$|[?#])", RegexOption.IGNORE_CASE)
    private val m3u8Reference = Regex(
        """(?i)((?:https?:)?//[^\s"'<>\\]+?\.m3u8(?:\?[^\s"'<>\\]*)?|(?:\.\.?/|/)[^\s"'<>\\]+?\.m3u8(?:\?[^\s"'<>\\]*)?|[A-Za-z0-9_%@+.-]+(?:/[A-Za-z0-9_%@+.,~!$&()*;=:-]+)*\.m3u8(?:\?[^\s"'<>\\]*)?)""",
    )
    private val mediaAttributeNames = listOf(
        "src", "data-src", "data-hls-src", "data-video-src",
        "data-playlist", "data-file", "data-url",
    )

    fun extract(html: String): HtmlMediaExtraction {
        val document = Jsoup.parse(html)
        val media = mutableListOf<ExtractedHtmlMedia>()
        val frames = mutableListOf<ExtractedHtmlFrame>()

        document.select("video").forEach { video ->
            appendMediaReferences(
                element = video,
                poster = video.firstNonBlank("poster", "data-poster"),
                title = elementTitle(video),
                origin = HlsCandidateOrigin.VIDEO,
                destination = media,
            )
        }
        document.select("source").forEach { source ->
            val video = source.parents().firstOrNull { it.normalName() == "video" }
            appendMediaReferences(
                element = source,
                poster = source.firstNonBlank("poster", "data-poster")
                    ?: video?.firstNonBlank("poster", "data-poster"),
                title = elementTitle(source) ?: video?.let(::elementTitle),
                origin = HlsCandidateOrigin.SOURCE,
                destination = media,
            )
        }

        document.allElements.forEach { element ->
            if (element.normalName() == "video" || element.normalName() == "source") return@forEach
            listOf("data-hls", "data-hls-src", "data-playlist", "data-file", "data-url")
                .forEach { name ->
                    val raw = element.attr(name).trim().takeIf(String::isNotEmpty) ?: return@forEach
                    if (!isLikelyHls(raw, null)) return@forEach
                    media += ExtractedHtmlMedia(
                        rawUrl = raw,
                        rawPosterUrl = element.attr("data-poster").trim().ifEmpty { null },
                        title = elementTitle(element),
                        origin = HlsCandidateOrigin.INLINE_SCRIPT,
                    )
                }
        }

        document.select("iframe").forEach { iframe ->
            val title = elementTitle(iframe)
            val sourceDocument = iframe.attr("srcdoc").takeIf { iframe.hasAttr("srcdoc") }
            if (sourceDocument != null) {
                frames += ExtractedHtmlFrame(null, sourceDocument, title)
            } else {
                val seen = mutableSetOf<String>()
                listOf("src", "data-src", "data-lazy-src", "data-url").forEach { name ->
                    val raw = iframe.attr(name).trim().takeIf(String::isNotEmpty) ?: return@forEach
                    val key = normalizedReferenceKey(raw)
                    if (seen.add(key)) frames += ExtractedHtmlFrame(raw, null, title)
                }
            }
        }

        val structured = media.mapTo(mutableSetOf()) { normalizedReferenceKey(it.rawUrl) }
        val looseDocument = document.clone()
        looseDocument.select("iframe[srcdoc]").remove()
        extractM3u8Strings(looseDocument.outerHtml()).forEach { raw ->
            if (structured.add(normalizedReferenceKey(raw))) {
                media += ExtractedHtmlMedia(raw, null, null, HlsCandidateOrigin.INLINE_SCRIPT)
            }
        }

        val pageTitle = normalizedText(document.title())
        val metadataTitle = document.selectFirst(
            "meta[property=og:title],meta[name=twitter:title]",
        )?.attr("content")?.let(::normalizedText)
        val thumbnail = document.selectFirst(
            "meta[property=og:image],meta[property=og:image:url]," +
                "meta[property=og:image:secure_url],meta[name=twitter:image],meta[name=twitter:image:src]",
        )?.attr("content")?.trim()?.ifEmpty { null }

        return HtmlMediaExtraction(
            baseHref = document.selectFirst("base[href]")?.attr("href")?.trim()?.ifEmpty { null },
            title = pageTitle ?: metadataTitle,
            rawThumbnailUrl = thumbnail,
            media = media,
            frames = frames,
        )
    }

    fun extractM3u8Strings(text: String): List<String> {
        val decoded = UriResolver.decodeEscapes(Parser.unescapeEntities(text, false))
        val seen = mutableSetOf<String>()
        return m3u8Reference.findAll(decoded).mapNotNull { match ->
            val raw = match.groupValues[1].trim('(', ')', '[', ']', '{', '}', ';', ',')
            raw.takeIf { it.isNotEmpty() && seen.add(normalizedReferenceKey(it)) }
        }.toList()
    }

    private fun appendMediaReferences(
        element: Element,
        poster: String?,
        title: String?,
        origin: HlsCandidateOrigin,
        destination: MutableList<ExtractedHtmlMedia>,
    ) {
        val mimeType = element.attr("type").trim().lowercase().ifEmpty { null }
        val seen = mutableSetOf<String>()
        mediaAttributeNames.forEach { name ->
            val raw = element.attr(name).trim().takeIf(String::isNotEmpty) ?: return@forEach
            if (!isLikelyHls(raw, mimeType) || !seen.add(normalizedReferenceKey(raw))) return@forEach
            destination += ExtractedHtmlMedia(raw, poster, title, origin)
        }
    }

    private fun isLikelyHls(rawUrl: String, mimeType: String?): Boolean =
        mimeType in hlsMimeTypes || m3u8Suffix.containsMatchIn(UriResolver.decodeEscapes(rawUrl))

    private fun elementTitle(element: Element): String? =
        element.firstNonBlank("title", "aria-label", "data-title")?.let(::normalizedText)

    private fun Element.firstNonBlank(vararg names: String): String? = names.firstNotNullOfOrNull { name ->
        attr(name).trim().ifEmpty { null }
    }

    private fun normalizedText(value: String): String? = Parser.unescapeEntities(value, false)
        .replace(Regex("<[^>]+>"), " ")
        .split(Regex("\\s+"))
        .filter(String::isNotEmpty)
        .joinToString(" ")
        .ifEmpty { null }

    private fun normalizedReferenceKey(value: String): String = UriResolver.decodeEscapes(value).trim()
}
