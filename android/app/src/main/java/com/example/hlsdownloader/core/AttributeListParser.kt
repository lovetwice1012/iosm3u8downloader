package com.example.hlsdownloader.core

object AttributeListParser {
    fun parse(text: String): Map<String, String> {
        val fields = mutableListOf<String>()
        val current = StringBuilder()
        var insideQuotes = false
        text.forEach { character ->
            when {
                character == '"' -> {
                    insideQuotes = !insideQuotes
                    current.append(character)
                }
                character == ',' && !insideQuotes -> {
                    fields += current.toString()
                    current.clear()
                }
                else -> current.append(character)
            }
        }
        if (current.isNotEmpty()) fields += current.toString()

        return buildMap {
            fields.forEach { field ->
                val equals = field.indexOf('=')
                if (equals < 0) return@forEach
                val key = field.substring(0, equals).trim().uppercase()
                var value = field.substring(equals + 1).trim()
                if (value.length >= 2 && value.first() == '"' && value.last() == '"') {
                    value = value.substring(1, value.length - 1)
                }
                put(key, value)
            }
        }
    }
}
