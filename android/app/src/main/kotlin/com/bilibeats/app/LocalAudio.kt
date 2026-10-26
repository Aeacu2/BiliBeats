package com.bilibeats.app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/// Songs from the phone's own storage (设置 → 导入本地歌曲, or a file opened
/// with BiliBeats): each one copied into the app's audio folder, where the
/// library keeps it like a download. The Dart side (LocalSongs) names the
/// copy after its content and adds it to the library.
object LocalAudio {
    /// Larger than any song; a film's soundtrack would be one, not a song.
    private const val MAX_BYTES = 1L shl 30

    /// Album art is shown at phone size: a larger picture is left out.
    private const val MAX_PICTURE_BYTES = 4 shl 20

    private fun audioDir(context: Context): File =
        File(context.getDir("flutter", Context.MODE_PRIVATE), "bilibeat_audio")
            .apply { mkdirs() }

    /// Copies [uri] into the audio folder and reads its tags. The copy is a
    /// `.part` file: a launch clears one only after a week, so a song opened
    /// as the app starts is not swept away before the library takes it. On
    /// failure the map holds only `error` and `name`.
    fun copy(context: Context, uri: Uri): Map<String, Any?> {
        val name = displayName(context, uri)
        val target = File(audioDir(context), "incoming_${UUID.randomUUID()}.part")
        try {
            val digest = MessageDigest.getInstance("SHA-1")
            var size = 0L
            val input = context.contentResolver.openInputStream(uri)
                ?: return failure(name, "unreadable")
            input.use { source ->
                target.outputStream().use { sink ->
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        size += read
                        if (size > MAX_BYTES) {
                            target.delete()
                            return failure(name, "too large")
                        }
                        digest.update(buffer, 0, read)
                        sink.write(buffer, 0, read)
                    }
                }
            }
            if (size == 0L) {
                target.delete()
                return failure(name, "empty")
            }
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(target.path)
                fun tag(key: Int) = retriever.extractMetadata(key)?.trim()?.ifEmpty { null }
                if (tag(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) != "yes") {
                    target.delete()
                    return failure(name, "not audio")
                }
                val picture = retriever.embeddedPicture
                return mapOf(
                    "path" to target.path,
                    "hash" to digest.digest().joinToString("") { "%02x".format(it) },
                    "name" to name,
                    "title" to tag(MediaMetadataRetriever.METADATA_KEY_TITLE),
                    "artist" to (
                        tag(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                            ?: tag(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST)
                        ),
                    "album" to tag(MediaMetadataRetriever.METADATA_KEY_ALBUM),
                    "durationMs" to
                        tag(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(),
                    "picture" to picture?.takeIf { it.size <= MAX_PICTURE_BYTES },
                )
            } finally {
                retriever.release()
            }
        } catch (e: Exception) {
            target.delete()
            return failure(name, e.javaClass.simpleName)
        }
    }

    private fun failure(name: String?, reason: String): Map<String, Any?> =
        mapOf("error" to reason, "name" to name)

    private fun displayName(context: Context, uri: Uri): String? {
        try {
            context.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name = cursor.getString(0)
                    if (!name.isNullOrBlank()) return name
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }
}
