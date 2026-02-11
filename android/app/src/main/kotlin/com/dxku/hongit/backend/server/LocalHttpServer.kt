package com.dxku.hongit.backend.server

import com.dxku.hongit.backend.DownloadService
import com.dxku.hongit.backend.saavn.SaavnService
import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject

class LocalHttpServer(
    port: Int = 8080,
    private val context: android.content.Context
) : NanoHTTPD(port) {

    override fun serve(session: IHTTPSession): Response {
        return try {
            when {

                session.uri == "/health" -> {
                    newFixedLengthResponse(
                        Response.Status.OK,
                        "application/json",
                        """{"status":"ok","service":"local-backend"}"""
                    )
                }

                session.uri == "/search/saavn" -> {
                    val query = session.parameters["q"]?.firstOrNull()

                    if (query.isNullOrBlank()) {
                        return newFixedLengthResponse(
                            Response.Status.BAD_REQUEST,
                            "application/json",
                            """{"error":"missing_query"}"""
                        )
                    }

                    val result = SaavnService.searchSongs(query)

                    newFixedLengthResponse(
                        Response.Status.OK,
                        "application/json",
                        result
                    )
                }

                session.uri.startsWith("/song/saavn/") -> {
                    val id = session.uri.removePrefix("/song/saavn/").trim()
                    if (id.isBlank()) {
                        return newFixedLengthResponse(
                            Response.Status.BAD_REQUEST,
                            "application/json",
                            """{"error":"missing_id"}"""
                        )
                    }

                    val url = "https://saavn.sumit.co/api/songs/$id"
                    val req = okhttp3.Request.Builder().url(url).get().build()

                    val client = okhttp3.OkHttpClient()
                    client.newCall(req).execute().use { resp ->
                        if (!resp.isSuccessful) {
                            return newFixedLengthResponse(
                                Response.Status.INTERNAL_ERROR,
                                "application/json",
                                """{"error":"saavn_fetch_failed"}"""
                            )
                        }

                        val body = resp.body?.string() ?: "{}"
                        return newFixedLengthResponse(
                            Response.Status.OK,
                            "application/json",
                            body
                        )
                    }
                }

                session.uri == "/download/saavn" &&
                        session.method == Method.POST -> {

                    val body = HashMap<String, String>()
                    session.parseBody(body)

                    val json = body["postData"]
                        ?: return newFixedLengthResponse(
                            Response.Status.BAD_REQUEST,
                            "application/json",
                            """{"error":"missing_body"}"""
                        )

                    val obj = JSONObject(json)
                    val title = obj.optString("title")
                    val songId = obj.optString("songId")

                    if (title.isBlank() || songId.isBlank()) {
                        return newFixedLengthResponse(
                            Response.Status.BAD_REQUEST,
                            "application/json",
                            """{"error":"missing_title_or_songId"}"""
                        )
                    }

                    // Fetch song details from Saavn API
                    val songUrl = "https://saavn.sumit.co/api/songs/$songId"
                    val songReq = okhttp3.Request.Builder().url(songUrl).get().build()

                    val client = okhttp3.OkHttpClient()
                    val downloadUrl = client.newCall(songReq).execute().use { resp ->
                        if (!resp.isSuccessful) {
                            return newFixedLengthResponse(
                                Response.Status.INTERNAL_ERROR,
                                "application/json",
                                """{"error":"failed_to_fetch_song"}"""
                            )
                        }

                        val songData = resp.body?.string() ?: "{}"
                        val songJson = JSONObject(songData)
                        val data = songJson.getJSONArray("data")

                        if (data.length() == 0) {
                            return newFixedLengthResponse(
                                Response.Status.INTERNAL_ERROR,
                                "application/json",
                                """{"error":"no_song_data"}"""
                            )
                        }

                        val song = data.getJSONObject(0)
                        val downloadUrls = song.getJSONArray("downloadUrl")

                        if (downloadUrls.length() == 0) {
                            return newFixedLengthResponse(
                                Response.Status.INTERNAL_ERROR,
                                "application/json",
                                """{"error":"no_download_urls"}"""
                            )
                        }

                        // Find best quality URL (prefer 320kbps, fallback to lower)
                        var bestUrl = ""
                        val preferredQualities = listOf("320kbps", "160kbps", "96kbps", "48kbps", "12kbps")

                        for (quality in preferredQualities) {
                            for (i in 0 until downloadUrls.length()) {
                                val urlObj = downloadUrls.getJSONObject(i)
                                if (urlObj.getString("quality") == quality) {
                                    bestUrl = urlObj.getString("url")
                                    break
                                }
                            }
                            if (bestUrl.isNotEmpty()) break
                        }

                        if (bestUrl.isEmpty()) {
                            // Fallback to last item if quality matching fails
                            bestUrl = downloadUrls.getJSONObject(downloadUrls.length() - 1).getString("url")
                        }

                        bestUrl
                    }

                    DownloadService.start(context, title, downloadUrl)

                    newFixedLengthResponse(
                        Response.Status.OK,
                        "application/json",
                        """{"status":"queued"}"""
                    )
                }

                session.uri == "/download/direct" &&
                        session.method == Method.POST -> {

                    val body = HashMap<String, String>()
                    session.parseBody(body)

                    val json = body["postData"]
                        ?: return newFixedLengthResponse(
                            Response.Status.BAD_REQUEST,
                            "application/json",
                            """{"error":"missing_body"}"""
                        )

                    val obj = JSONObject(json)
                    val title = obj.optString("title")
                    val url = obj.optString("url")

                    if (title.isBlank() || url.isBlank()) {
                        return newFixedLengthResponse(
                            Response.Status.BAD_REQUEST,
                            "application/json",
                            """{"error":"missing_title_or_url"}"""
                        )
                    }

                    DownloadService.start(context, title, url)

                    newFixedLengthResponse(
                        Response.Status.OK,
                        "application/json",
                        """{"status":"queued"}"""
                    )
                }

                else -> {
                    newFixedLengthResponse(
                        Response.Status.NOT_FOUND,
                        "application/json",
                        """{"error":"not_found"}"""
                    )
                }
            }
        } catch (e: Exception) {
            newFixedLengthResponse(
                Response.Status.INTERNAL_ERROR,
                "application/json",
                """{"error":"${e.message}"}"""
            )
        }
    }
}