package com.innosquad.innonetwork.runtimesmoke

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import com.innosquad.innonetwork.NetworkSessionConfiguration
import com.innosquad.innonetwork.OkHttpNetworkSession
import com.innosquad.innonetwork.ResponseBodyTooLargeException
import com.innosquad.innonetwork.client.DefaultNetworkClient
import com.innosquad.innonetwork.client.codegen.InnoEndpoint
import com.innosquad.innonetwork.serialization.decodeJson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.serializer
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

@InnoEndpoint(method = "GET", path = "/api/message")
public class SmokeMessageEndpoint

/** Exercises published artifacts after D8/R8 on an actual Android runtime. */
public class SmokeActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val status = TextView(this).apply { text = "Running InnoNetwork runtime smoke" }
        setContentView(status)
        val runID = intent.getStringExtra("run-id") ?: "manual"
        val baseUrl = (intent.getStringExtra("base-url") ?: "http://127.0.0.1:4173/").toHttpUrl()
        scope.launch {
            try {
                check(baseUrl.host == "127.0.0.1") { "The smoke fixture must use loopback" }
                val native = OkHttpClient()
                val session = OkHttpNetworkSession(native)
                val client = DefaultNetworkClient(baseUrl, session)
                val endpoint = SmokeMessageEndpoint().apiDefinition { it.decodeJson(String.serializer()) }
                val messages = coroutineScope {
                    (1..8).map { async { client.request(endpoint) } }.awaitAll()
                }
                check(messages.all { it == "hello from Chromium" })
                val smallSession = OkHttpNetworkSession(native, NetworkSessionConfiguration.bounded(2))
                val compressed = Request.Builder().url(baseUrl.newBuilder().addPathSegments("api/compressed").build()).build()
                check(smallSession.data(compressed).bodyText() == "ok")
                val oversized = Request.Builder().url(baseUrl.newBuilder().addPathSegments("api/message").build()).build()
                try {
                    smallSession.data(oversized)
                    error("Expected a bounded response failure")
                } catch (expected: ResponseBodyTooLargeException) {
                    check(expected.limitBytes == 2L)
                }
                session.open(oversized).use { check(it.source.readUtf8().contains("hello from Chromium")) }
                val slow = Request.Builder().url(baseUrl.newBuilder().addPathSegments("api/slow").build()).build()
                val operation = launch { session.data(slow) }
                delay(25)
                operation.cancelAndJoin()
                check(operation.isCancelled)
                native.connectionPool.evictAll()
                native.dispatcher.executorService.shutdown()
                Log.i("InnoNetworkSmoke", "$runID OK: KSP JSON concurrent gzip limit stream cancellation")
                runOnUiThread { status.text = "InnoNetwork Android runtime: OK" }
            } catch (failure: Exception) {
                Log.e("InnoNetworkSmoke", "$runID FAILED", failure)
                runOnUiThread { status.text = "InnoNetwork Android runtime: FAILED" }
            }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
