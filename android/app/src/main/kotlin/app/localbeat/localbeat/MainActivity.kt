package app.localbeat.localbeat

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val artworkWorker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pendingPicker: MethodChannel.Result? = null
    private var scan: Iterator<Map<String, Any?>>? = null
    private var scanFolder: String? = null
    private val formats = setOf("mp3", "aac", "m4a", "flac", "wav", "ogg", "oga", "opus")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.localbeat/library")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFolder" -> {
                        if (pendingPicker != null) { result.error("busy", "Folder picker already open", null) }
                        else {
                            pendingPicker = result
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                            }
                            startActivityForResult(intent, 7301)
                        }
                    }
                    "scanPage" -> worker.execute {
                        try {
                            val folder = call.argument<String>("folder")!!
                            val known = call.argument<List<Map<String, Any?>>>("known")
                            if (known != null) {
                                val fingerprints = known.associateBy { it["id"] as String }
                                scan = scanTree(Uri.parse(folder), fingerprints).iterator()
                                scanFolder = folder
                            }
                            check(scanFolder == folder) { "Scan session expired" }
                            val page = mutableListOf<Map<String, Any?>>()
                            val iterator = scan!!
                            while (page.size < 64 && iterator.hasNext()) page.add(iterator.next())
                            main.post { result.success(page) }
                        } catch (e: Exception) {
                            scan = null; scanFolder = null
                            main.post { result.error("scan_failed", e.message, null) }
                        }
                    }
                    "artwork" -> artworkWorker.execute {
                        val path = try { artwork(Uri.parse(call.argument<String>("uri")!!)) } catch (_: Exception) { null }
                        main.post { result.success(path) }
                    }
                    "releaseFolder" -> {
                        try {
                            contentResolver.releasePersistableUriPermission(Uri.parse(call.argument<String>("uri")!!),
                                Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        } catch (_: SecurityException) { }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
    @Deprecated("Activity result bridge for the platform channel")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7301) return
        val result = pendingPicker ?: return
        pendingPicker = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(null); return }
        try {
            val uri = data.data!!
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val id = DocumentsContract.getTreeDocumentId(uri)
            result.success(mapOf("uri" to uri.toString(), "name" to id.substringAfterLast('/').substringAfterLast(':').ifEmpty { "Music" }))
        } catch (e: Exception) { result.error("permission", e.message, null) }
    }
    private fun scanTree(tree: Uri, known: Map<String, Map<String, Any?>>): Sequence<Map<String, Any?>> = sequence {
        val directories = ArrayDeque<String>()
        val visited = HashSet<String>()
        directories.add(DocumentsContract.getTreeDocumentId(tree))
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_SIZE)
        while (directories.isNotEmpty()) {
            val dir = directories.removeFirst()
            if (!visited.add(dir)) continue
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dir)
            val cursor = try {
                contentResolver.query(children, columns, null, null, null)
            } catch (e: Exception) {
                if (visited.size == 1) throw IllegalStateException("Folder is unavailable", e)
                null
            }
            if (cursor == null) {
                if (visited.size == 1) throw IllegalStateException("Folder is unavailable")
                continue
            }
            cursor.use {
                // Close each directory cursor before yielding any metadata work.
                val files = mutableListOf<Array<Any>>()
                while (it.moveToNext()) {
                    val docId = it.getString(0)
                    val name = it.getString(1) ?: "Untitled"
                    val mime = it.getString(2) ?: ""
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) directories.add(docId)
                    else if (name.substringAfterLast('.', "").lowercase() in formats || mime.startsWith("audio/"))
                        files.add(arrayOf(docId, name, it.getLong(3), it.getLong(4)))
                }
                files
            }.forEach { file ->
                val docId = file[0] as String
                val name = file[1] as String
                val modified = file[2] as Long
                val size = file[3] as Long
                val id = "${tree.authority}:$docId"
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
                val previous = known[id]
                if (modified > 0 && previous != null && (previous["modified"] as? Number)?.toLong() == modified &&
                    (previous["size"] as? Number)?.toLong() == size) {
                    yield(mapOf("id" to id, "uri" to uri.toString(), "unchanged" to true))
                } else {
                    yield(metadata(id, uri, name, modified, size))
                }
            }
        }
    }
    private fun metadata(id: String, uri: Uri, name: String, modified: Long, size: Long): Map<String, Any?> {
        // A changed file may also contain new artwork. Invalidate only its generated thumbnails.
        val hash = MessageDigest.getInstance("SHA-256").digest(uri.toString().toByteArray())
            .joinToString("") { "%02x".format(it) }
        File(cacheDir, "artwork/$hash.jpg").delete()
        File(cacheDir, "artwork/$hash.none").delete()
        val m = mutableMapOf<String, Any?>("id" to id, "uri" to uri.toString(),
            "title" to name.substringBeforeLast('.'), "artist" to "Unknown artist", "album" to "Unknown album",
            "album_artist" to "", "format" to name.substringAfterLast('.', "").uppercase(),
            "modified" to modified, "size" to size, "art_path" to uri.toString())
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(applicationContext, uri)
            fun text(key: Int) = retriever.extractMetadata(key)?.trim()?.takeIf { it.isNotEmpty() }
            text(MediaMetadataRetriever.METADATA_KEY_TITLE)?.let { m["title"] = it }
            text(MediaMetadataRetriever.METADATA_KEY_ARTIST)?.let { m["artist"] = it }
            text(MediaMetadataRetriever.METADATA_KEY_ALBUM)?.let { m["album"] = it }
            text(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST)?.let { m["album_artist"] = it }
            m["duration_ms"] = text(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            m["track_number"] = text(MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER)?.substringBefore('/')?.toIntOrNull() ?: 0
            m["disc_number"] = text(MediaMetadataRetriever.METADATA_KEY_DISC_NUMBER)?.substringBefore('/')?.toIntOrNull() ?: 0
        } catch (_: Exception) { /* Keep a browsable filename entry even if tags are malformed. */ }
        finally { retriever.release() }
        return m
    }
    private fun artwork(uri: Uri): String? {
        val dir = File(cacheDir, "artwork").apply { mkdirs() }
        val hash = MessageDigest.getInstance("SHA-256").digest(uri.toString().toByteArray())
            .joinToString("") { "%02x".format(it) }
        val file = File(dir, "$hash.jpg")
        val absent = File(dir, "$hash.none")
        if (file.exists()) { file.setLastModified(System.currentTimeMillis()); return file.path }
        if (absent.exists()) return null
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(applicationContext, uri)
            val bytes = r.embeddedPicture
            if (bytes == null) { absent.createNewFile(); return null }
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            var sample = 1
            while (opts.outWidth / sample > 768 || opts.outHeight / sample > 768) sample *= 2
            opts.inJustDecodeBounds = false; opts.inSampleSize = sample
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: return null
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            bitmap.recycle()
            val cached = dir.listFiles()?.filter { it.extension == "jpg" }?.sortedBy { it.lastModified() } ?: emptyList()
            var total = cached.sumOf { it.length() }
            for (old in cached) {
                if (total <= 96L * 1024 * 1024) break
                if (old != file) { total -= old.length(); old.delete() }
            }
            return file.path
        } finally { r.release() }
    }
}
