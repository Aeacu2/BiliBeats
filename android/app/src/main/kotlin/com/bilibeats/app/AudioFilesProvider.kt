package com.bilibeats.app

import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/// The downloaded songs, shown in the system Files app (and any app that
/// opens documents) as a "BiliBeats" location: one read-only folder of
/// `.m4a` files named after the songs. Copy, share or open them from there.
///
/// The audio itself stays where the app keeps it (`app_flutter/
/// bilibeat_audio/audio_<id>.m4a`, private storage no file manager can
/// reach); nothing is copied. Read-only on purpose: a file deleted or
/// replaced behind the app's back would leave a song in the library that
/// no longer plays.
class AudioFilesProvider : DocumentsProvider() {
    companion object {
        const val ROOT_ID = "bilibeats"
        const val FOLDER_ID = "audio"
        private const val FILE_PREFIX = "audio/"

        fun authority(context: Context) = "${context.packageName}.audiofiles"

        private val ROOT_COLUMNS = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_FLAGS,
            Root.COLUMN_TITLE,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_ICON,
        )
        private val DOCUMENT_COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )
        private val SAFE_ID = Regex("^[A-Za-z0-9_-]{1,80}$")
        private val UNSAFE_NAME_CHARS = Regex("[\\\\/:*?\"<>|\\x00-\\x1f]")
    }

    override fun onCreate(): Boolean = true

    private fun docs(): File = context!!.getDir("flutter", Context.MODE_PRIVATE)

    private fun audioDir(): File = File(docs(), "bilibeat_audio")

    /// Downloaded songs: an `.m4a` with its `.ready` marker (a partial or
    /// unverified file is not one), by track id.
    private fun songs(): Map<String, File> {
        val dir = audioDir()
        val files = dir.listFiles() ?: return emptyMap()
        val out = LinkedHashMap<String, File>()
        for (file in files.sortedByDescending { it.lastModified() }) {
            val name = file.name
            if (!name.startsWith("audio_") || !name.endsWith(".m4a")) continue
            val id = name.removePrefix("audio_").removeSuffix(".m4a")
            if (!SAFE_ID.matches(id)) continue
            if (!File(dir, "audio_$id.ready").exists()) continue
            out[id] = file
        }
        return out
    }

    private var namesStamp = -1L
    private var namesCache: Map<String, String> = emptyMap()

    /// "歌名 - 歌手" for each song the library has named, else the video's
    /// title — read from the library file, re-read when it changes.
    @Synchronized
    private fun names(): Map<String, String> {
        val file = File(docs(), "bilibeat_downloaded.json")
        val stamp = if (file.exists()) file.lastModified() else 0L
        if (stamp == namesStamp) return namesCache
        val names = HashMap<String, String>()
        try {
            if (file.exists()) {
                val text = file.readText()
                // Written in an envelope ({"schema_version", "data"}), or bare
                // by versions before it.
                val list: JSONArray? = if (text.trimStart().startsWith("{")) {
                    JSONObject(text).optJSONArray("data")
                } else {
                    JSONArray(text)
                }
                if (list != null) {
                    for (i in 0 until list.length()) {
                        val track = list.optJSONObject(i) ?: continue
                        val id = track.optString("id")
                        val title = track.optString("title").trim()
                        if (id.isEmpty() || title.isEmpty()) continue
                        val artist = track.optString("uploader").trim()
                        val named = track.optBoolean("named") ||
                            title != track.optString("rawTitle").trim()
                        names[id] =
                            if (named && artist.isNotEmpty()) "$title - $artist" else title
                    }
                }
            }
        } catch (_: Exception) {
            // Unreadable right now (mid-write): ids stand in until next time.
        }
        namesStamp = stamp
        namesCache = names
        return names
    }

    /// File names, unique within the folder.
    private fun displayNames(ids: Collection<String>): Map<String, String> {
        val names = names()
        val taken = HashSet<String>()
        val out = HashMap<String, String>()
        for (id in ids) {
            val base = (names[id] ?: id)
                .replace(UNSAFE_NAME_CHARS, "_")
                .take(120)
                .ifBlank { id }
            var name = "$base.m4a"
            var n = 2
            while (!taken.add(name.lowercase())) {
                name = "$base ($n).m4a"
                n++
            }
            out[id] = name
        }
        return out
    }

    private fun fileOf(documentId: String): File {
        if (!documentId.startsWith(FILE_PREFIX)) {
            throw FileNotFoundException(documentId)
        }
        val id = documentId.removePrefix(FILE_PREFIX)
        if (!SAFE_ID.matches(id)) throw FileNotFoundException(documentId)
        return songs()[id] ?: throw FileNotFoundException(documentId)
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: ROOT_COLUMNS)
        cursor.newRow()
            .add(Root.COLUMN_ROOT_ID, ROOT_ID)
            .add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY)
            .add(Root.COLUMN_TITLE, "BiliBeats")
            .add(Root.COLUMN_DOCUMENT_ID, FOLDER_ID)
            .add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
        return cursor
    }

    private fun addFolder(cursor: MatrixCursor) {
        cursor.newRow()
            .add(Document.COLUMN_DOCUMENT_ID, FOLDER_ID)
            .add(Document.COLUMN_DISPLAY_NAME, "BiliBeats")
            .add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            .add(Document.COLUMN_SIZE, null)
            .add(Document.COLUMN_LAST_MODIFIED, audioDir().lastModified())
            .add(Document.COLUMN_FLAGS, 0)
    }

    private fun addSong(cursor: MatrixCursor, id: String, file: File, name: String) {
        cursor.newRow()
            .add(Document.COLUMN_DOCUMENT_ID, FILE_PREFIX + id)
            .add(Document.COLUMN_DISPLAY_NAME, name)
            .add(Document.COLUMN_MIME_TYPE, "audio/mp4")
            .add(Document.COLUMN_SIZE, file.length())
            .add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
            .add(Document.COLUMN_FLAGS, 0)
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_COLUMNS)
        if (documentId == FOLDER_ID) {
            addFolder(cursor)
        } else {
            val file = fileOf(documentId)
            val id = documentId.removePrefix(FILE_PREFIX)
            // Named as in the folder listing, duplicates included.
            val name = displayNames(songs().keys)[id] ?: "$id.m4a"
            addSong(cursor, id, file, name)
        }
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_COLUMNS)
        if (parentDocumentId != FOLDER_ID) return cursor
        val songs = songs()
        val names = displayNames(songs.keys)
        for ((id, file) in songs) addSong(cursor, id, file, names[id] ?: "$id.m4a")
        cursor.setNotificationUri(
            context!!.contentResolver,
            android.provider.DocumentsContract.buildChildDocumentsUri(
                authority(context!!), FOLDER_ID,
            ),
        )
        return cursor
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        parentDocumentId == FOLDER_ID && documentId.startsWith(FILE_PREFIX)

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("read-only: $documentId")
        return ParcelFileDescriptor.open(fileOf(documentId), ParcelFileDescriptor.MODE_READ_ONLY)
    }
}
