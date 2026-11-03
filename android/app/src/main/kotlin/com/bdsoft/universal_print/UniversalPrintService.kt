package com.bdsoft.universal_print

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PrintAttributes
import android.print.PrinterCapabilitiesInfo
import android.print.PrinterId
import android.print.PrinterInfo
import android.printservice.PrintJob
import android.printservice.PrintService
import android.printservice.PrinterDiscoverySession
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * Makes Universal Print a system printer on Android: after it is turned on
 * in Settings → Connected devices → Printing, every receipt / label / A4
 * printer set up in the app appears in the Print dialog of any app (Chrome,
 * PDF viewers, Gallery, Office…), with no extra driver.
 *
 * Android hands over a PDF. Receipt and label printers get each page
 * rendered at the printer's dot width with [PdfRenderer]; Dart converts the
 * pages to black and white and queues them (`submitSystemPages`). A4 / IPP
 * printers get the PDF untouched.
 */
class UniversalPrintService : PrintService() {

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** Last printer list from Dart, by printer id. */
    private val known = HashMap<String, Map<*, *>>()

    override fun onCreatePrinterDiscoverySession(): PrinterDiscoverySession = Session()

    override fun onRequestCancelPrintJob(printJob: PrintJob) {
        printJob.cancel()
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    private fun loadPrinters(done: (List<Map<*, *>>) -> Unit) {
        PrintEngine.obtain(this)
        val host = PrintEngine.host ?: return done(emptyList())
        host.request("systemPrinters", null) { result ->
            @Suppress("UNCHECKED_CAST")
            val list = (result["printers"] as? List<Map<*, *>>) ?: emptyList()
            known.clear()
            list.forEach { p -> known[p["id"] as String] = p }
            done(list)
        }
    }

    private fun info(p: Map<*, *>): PrinterInfo {
        val id = generatePrinterId(p["id"] as String)
        val name = p["name"] as String
        val kind = p["kind"] as String
        val widthMm = (p["width_mm"] as Number).toInt()
        val heightMm = (p["height_mm"] as Number).toInt()
        val dpi = (p["dpi"] as Number).toInt()
        val caps = PrinterCapabilitiesInfo.Builder(id)
            .setMinMargins(PrintAttributes.Margins(0, 0, 0, 0))
        if (kind == "document") {
            caps.addMediaSize(PrintAttributes.MediaSize.ISO_A4, true)
                .addMediaSize(PrintAttributes.MediaSize.NA_LETTER, false)
                .addResolution(PrintAttributes.Resolution("r300", "300 dpi", 300, 300), true)
                .setColorModes(
                    PrintAttributes.COLOR_MODE_MONOCHROME or PrintAttributes.COLOR_MODE_COLOR,
                    PrintAttributes.COLOR_MODE_MONOCHROME,
                )
        } else {
            val label = if (kind == "label") "$widthMm×$heightMm mm label" else "$widthMm mm roll"
            caps.addMediaSize(
                PrintAttributes.MediaSize("up_${kind}_${widthMm}x$heightMm", label, mils(widthMm), mils(heightMm)),
                true,
            )
            if (kind == "roll") caps.addMediaSize(PrintAttributes.MediaSize.ISO_A4, false)
            caps.addResolution(PrintAttributes.Resolution("r$dpi", "$dpi dpi", dpi, dpi), true)
                .setColorModes(PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_MONOCHROME)
        }
        return PrinterInfo.Builder(id, name, PrinterInfo.STATUS_IDLE)
            .setDescription("Universal Print · ${p["description"]}")
            .setCapabilities(caps.build())
            .build()
    }

    private fun mils(mm: Int) = (mm * 1000 / 25.4).roundToInt()

    override fun onPrintJobQueued(printJob: PrintJob) {
        val localId = printJob.info.printerId?.localId
        val printer = localId?.let { known[it] }
        if (printer == null) {
            // Printer list is stale (e.g. the service restarted); reload once.
            loadPrinters {
                val again = localId?.let { id -> known[id] }
                if (again == null) printJob.fail("Printer not found in Universal Print") else start(printJob, again)
            }
            return
        }
        start(printJob, printer)
    }

    private fun start(job: PrintJob, printer: Map<*, *>) {
        if (job.isCancelled) return
        if (!job.isStarted) job.start()
        val fd = job.document.data
        if (fd == null) {
            job.fail("No document")
            return
        }
        val copies = job.info.copies.coerceIn(1, 20)
        val name = job.document.info.name
        io.execute {
            val args: Pair<String, Map<String, Any?>> = try {
                val pdf = copyToCache(fd)
                try {
                    if (printer["kind"] == "document") {
                        val payload = JSONObject()
                            .put("printer_id", printer["id"])
                            .put("document_type", "pdf")
                            .put("copies", copies)
                            .put("data", Base64.encodeToString(pdf.readBytes(), Base64.NO_WRAP))
                        "submitIntent" to mapOf("payload" to payload.toString(), "token" to null)
                    } else {
                        "submitSystemPages" to mapOf(
                            "printer_id" to printer["id"],
                            "copies" to copies,
                            "job_name" to name,
                            "pages" to render(pdf, (printer["dots"] as Number).toInt()),
                        )
                    }
                } finally {
                    pdf.delete()
                }
            } catch (e: Exception) {
                main.post { if (!job.isCancelled) job.fail(e.message ?: "Cannot read the document") }
                return@execute
            }
            main.post {
                if (job.isCancelled) return@post
                PrintEngine.obtain(this)
                val host = PrintEngine.host
                if (host == null) {
                    job.fail("Universal Print is not ready")
                    return@post
                }
                host.request(args.first, args.second) { result ->
                    if (job.isCancelled || job.isCompleted || job.isFailed) return@request
                    if (result["success"] == true) job.complete() else job.fail(result["error"]?.toString() ?: "Print failed")
                }
            }
        }
    }

    /** PdfRenderer needs a seekable file; Android may give a pipe. */
    private fun copyToCache(fd: ParcelFileDescriptor): File {
        val file = File.createTempFile("print", ".pdf", cacheDir)
        FileInputStream(fd.fileDescriptor).use { input -> file.outputStream().use { input.copyTo(it) } }
        fd.close()
        return file
    }

    /** One PNG per page, [dots] pixels wide, white paper. */
    private fun render(pdf: File, dots: Int): List<ByteArray> {
        val pages = ArrayList<ByteArray>()
        ParcelFileDescriptor.open(pdf, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
            PdfRenderer(pfd).use { renderer ->
                if (renderer.pageCount > 200) throw IllegalArgumentException("Document has more than 200 pages")
                for (i in 0 until renderer.pageCount) {
                    renderer.openPage(i).use { page ->
                        val height = (dots.toDouble() * page.height / page.width).roundToInt().coerceIn(1, 20000)
                        val bitmap = Bitmap.createBitmap(dots, height, Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                        val out = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                        bitmap.recycle()
                        pages.add(out.toByteArray())
                    }
                }
            }
        }
        return pages
    }

    private inner class Session : PrinterDiscoverySession() {
        override fun onStartPrinterDiscovery(priorityList: MutableList<PrinterId>) {
            loadPrinters { list ->
                if (isDestroyed) return@loadPrinters
                val infos = list.map { info(it) }
                val current = infos.map { it.id }.toSet()
                removePrinters(printers.map { it.id }.filter { it !in current })
                addPrinters(infos)
            }
        }

        override fun onStopPrinterDiscovery() {}

        override fun onValidatePrinters(printerIds: MutableList<PrinterId>) {}

        override fun onStartPrinterStateTracking(printerId: PrinterId) {
            val p = known[printerId.localId] ?: return
            addPrinters(listOf(info(p)))
        }

        override fun onStopPrinterStateTracking(printerId: PrinterId) {}

        override fun onDestroy() {}
    }
}
